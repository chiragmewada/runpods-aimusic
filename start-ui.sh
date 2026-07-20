#!/usr/bin/env bash
# Launch ace-step-ui plus the ACE-Step backend it talks to.
#
# Defaults to serving the UI on 7860 — the port already exposed for the Gradio
# setup — so no pod edit is needed. ACE-Step moves to 7861 on loopback, where it
# does not need to be publicly reachable. Vite proxies /api and /audio to 3001
# itself, so 3001 needs no exposure either.
set -euo pipefail

VOL="${VOL:-/workspace}"
UI_DIR="$VOL/ace-step-ui"
ACE_DIR="$VOL/ACE-Step-1.5"
NODE_DIR="$VOL/node"
LOG_DIR="$VOL/logs"
ACE_PORT="${ACE_PORT:-7861}"
UI_PORT="${UI_PORT:-7860}"

if [[ -z "${UI_USER:-}" || -z "${UI_PASS:-}" ]]; then
    echo "ERROR: set UI_USER and UI_PASS before starting." >&2
    echo "  export UI_USER=admin UI_PASS='<something-long>'" >&2
    exit 1
fi
if [[ ! -d "$UI_DIR/node_modules" ]]; then
    echo "ERROR: $UI_DIR not set up. Run ./setup-ui.sh first." >&2
    exit 1
fi
if [[ ! -x "$NODE_DIR/bin/node" ]]; then
    echo "ERROR: no Node at $NODE_DIR. Run ./setup-ui.sh first." >&2
    exit 1
fi

export PATH="$NODE_DIR/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
export HF_HOME="$VOL/hf-cache"
export UV_CACHE_DIR="$VOL/uv-cache"
export TOKENIZERS_PARALLELISM=false
# Both the REST calls and the @gradio/client connection read this one variable,
# and --enable-api mounts the REST routes onto the Gradio port, so it covers both.
export ACESTEP_API_URL="http://127.0.0.1:${ACE_PORT}"
# The backend resolves ACE-Step as <ui>/../../ACE-Step-1.5, i.e. inside the UI
# checkout, and falls back to env/bin/python when it finds no venv there — hence
# "spawn .../ace-step-ui/ACE-Step-1.5/env/bin/python ENOENT". Both are
# overridable, so point them at the real install.
export ACESTEP_PATH="$ACE_DIR"
export PYTHON_PATH="$ACE_DIR/.venv/bin/python"
export UI_PORT

if [[ ! -x "$PYTHON_PATH" ]]; then
    echo "ERROR: no Python at $PYTHON_PATH. Run ./setup.sh first." >&2
    exit 1
fi
mkdir -p "$LOG_DIR"

# Only the Express backend is stopped on exit. ACE-Step is deliberately left
# running: reloading the models costs several minutes of GPU time, and the
# restart path below reuses a live instance.
server_pid=""
cleanup() { [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Route-agnostic liveness check: whether anything is listening, without assuming
# what a given endpoint returns.
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# Kills by port rather than by command line. tsx runs the server in a child
# node process whose arguments do not mention tsx, so pattern-matching the
# command misses the process actually holding the socket.
kill_port() {
    local port="$1" pids=""
    # Every lookup needs `|| true`. Under `set -e`, an assignment that is the
    # last command of an && list takes the script down when it fails — and grep
    # exits 1 whenever the port is free, which is the normal case. That failure
    # is silent, so the script simply stopped here.
    pids=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u) || true
    if [[ -z "$pids" ]]; then
        pids=$(fuser -n tcp "$port" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$') || true
    fi
    if [[ -z "$pids" ]]; then
        pids=$(lsof -t -i ":$port" 2>/dev/null) || true
    fi
    [[ -z "$pids" ]] && return 0
    echo "[start-ui] stopping process(es) on port $port: $(echo "$pids" | tr '\n' ' ')"
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    for _ in $(seq 1 20); do port_open "$port" || return 0; sleep 0.5; done
    for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
    sleep 1
}

# ACE-Step binds loopback and runs without Gradio auth: @gradio/client cannot
# authenticate against a protected app, and loopback keeps it off the public
# proxy regardless of which ports the pod exposes.
if curl -sf "http://127.0.0.1:${ACE_PORT}/health" >/dev/null 2>&1; then
    echo "[start-ui] reusing ACE-Step already running on ${ACE_PORT}"
else
    echo "[start-ui] starting ACE-Step on 127.0.0.1:${ACE_PORT} (log: $LOG_DIR/acestep.log)"
    cd "$ACE_DIR"
    # setsid puts it in its own session, so Ctrl-C on this script does not reach
    # it. nohup alone is not enough: SIGINT goes to the whole process group, and
    # a background job in a script shares the script's group. Losing it costs a
    # multi-minute model reload, which is the thing keeping it warm avoids.
    setsid nohup uv run --no-sync acestep \
        --port "$ACE_PORT" \
        --server-name 127.0.0.1 \
        --language en \
        --config_path "${DIT_MODEL:-acestep-v15-turbo}" \
        --lm_model_path "${LM_MODEL:-acestep-5Hz-lm-1.7B}" \
        --init_service true \
        --enable-api \
        > "$LOG_DIR/acestep.log" 2>&1 &
    ace_pid=$!

    echo -n "[start-ui] loading models (several minutes)"
    ready=0
    for _ in $(seq 1 180); do
        if curl -sf "http://127.0.0.1:${ACE_PORT}/health" >/dev/null 2>&1; then
            ready=1; echo " ready"; break
        fi
        if ! kill -0 "$ace_pid" 2>/dev/null; then
            echo
            echo "ERROR: ACE-Step exited. Last 20 lines of $LOG_DIR/acestep.log:" >&2
            tail -20 "$LOG_DIR/acestep.log" >&2
            exit 1
        fi
        echo -n "."
        sleep 10
    done
    if [[ "$ready" -ne 1 ]]; then
        echo
        echo "ERROR: ACE-Step did not report healthy within 30 minutes." >&2
        tail -20 "$LOG_DIR/acestep.log" >&2
        exit 1
    fi
fi

# Always restarted, never reused. It starts in seconds, and a survivor from a
# previous run may predate a dependency reinstall — still running, but with its
# files replaced underneath it, which shows up as 500s rather than a clean crash.
kill_port 3001

echo "[start-ui] starting Express backend on 127.0.0.1:3001 (log: $LOG_DIR/ui-server.log)"
cd "$UI_DIR/server"
# node_modules/.bin directly rather than npx: npx re-resolves the package and
# is another thing that can hit the volume's exec-bit quirk.
nohup "$NODE_DIR/bin/node" "$UI_DIR/server/node_modules/tsx/dist/cli.mjs" src/index.ts \
    > "$LOG_DIR/ui-server.log" 2>&1 &
server_pid=$!

ready=0
for _ in $(seq 1 30); do
    if port_open 3001; then ready=1; break; fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "ERROR: Express backend exited. Last 20 lines of $LOG_DIR/ui-server.log:" >&2
        tail -20 "$LOG_DIR/ui-server.log" >&2
        exit 1
    fi
    sleep 2
done
if [[ "$ready" -ne 1 ]]; then
    echo "ERROR: Express backend did not open port 3001. Last 20 lines:" >&2
    tail -20 "$LOG_DIR/ui-server.log" >&2
    exit 1
fi

echo
echo "[start-ui] frontend on 0.0.0.0:${UI_PORT}"
echo "  open  https://<POD_ID>-${UI_PORT}.proxy.runpod.net"
echo
kill_port "$UI_PORT"
cd "$UI_DIR"
# Invoked through the node binary rather than the #!/usr/bin/env node shebang,
# so it does not depend on node being on PATH.
"$NODE_DIR/bin/node" "$UI_DIR/node_modules/vite/bin/vite.js" --config vite.config.runpod.ts
