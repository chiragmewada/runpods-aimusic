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
export UI_PORT
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

# ACE-Step binds loopback and runs without Gradio auth: @gradio/client cannot
# authenticate against a protected app, and loopback keeps it off the public
# proxy regardless of which ports the pod exposes.
if curl -sf "http://127.0.0.1:${ACE_PORT}/health" >/dev/null 2>&1; then
    echo "[start-ui] reusing ACE-Step already running on ${ACE_PORT}"
else
    echo "[start-ui] starting ACE-Step on 127.0.0.1:${ACE_PORT} (log: $LOG_DIR/acestep.log)"
    cd "$ACE_DIR"
    nohup uv run --no-sync acestep \
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

if port_open 3001; then
    # Left over from an earlier run that did not shut down cleanly. Reuse it
    # rather than failing with EADDRINUSE; ./stop-ui.sh clears it.
    echo "[start-ui] reusing Express backend already running on 3001"
else
    echo "[start-ui] starting Express backend on 127.0.0.1:3001 (log: $LOG_DIR/ui-server.log)"
    cd "$UI_DIR/server"
    # node_modules/.bin directly rather than npx: npx re-resolves the package and
    # is another thing that can hit the volume's exec-bit quirk.
    nohup "$UI_DIR/server/node_modules/.bin/tsx" src/index.ts > "$LOG_DIR/ui-server.log" 2>&1 &
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
fi

echo
echo "[start-ui] frontend on 0.0.0.0:${UI_PORT}"
echo "  open  https://<POD_ID>-${UI_PORT}.proxy.runpod.net"
echo
cd "$UI_DIR"
"$UI_DIR/node_modules/.bin/vite" --config vite.config.runpod.ts
