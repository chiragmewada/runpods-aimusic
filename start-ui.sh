#!/usr/bin/env bash
# Launch ace-step-ui plus the ACE-Step backend it talks to.
# Only port 3000 needs exposing: Vite proxies /api and /audio to 3001 itself,
# and ACE-Step is bound to loopback.
set -euo pipefail

VOL="${VOL:-/workspace}"
UI_DIR="$VOL/ace-step-ui"
ACE_DIR="$VOL/ACE-Step-1.5"
NODE_DIR="$VOL/node"
LOG_DIR="$VOL/logs"
ACE_PORT="${ACE_PORT:-7860}"
UI_PORT="${UI_PORT:-3000}"

if [[ -z "${UI_USER:-}" || -z "${UI_PASS:-}" ]]; then
    echo "ERROR: set UI_USER and UI_PASS before starting." >&2
    echo "  export UI_USER=admin UI_PASS='<something-long>'" >&2
    exit 1
fi
if [[ ! -d "$UI_DIR/node_modules" ]]; then
    echo "ERROR: $UI_DIR not set up. Run ./setup-ui.sh first." >&2
    exit 1
fi

export PATH="$NODE_DIR/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
export HF_HOME="$VOL/hf-cache"
export UV_CACHE_DIR="$VOL/uv-cache"
export TOKENIZERS_PARALLELISM=false
# Both the REST calls and the @gradio/client connection read this one variable,
# and --enable-api mounts the REST routes onto the Gradio port, so it covers both.
export ACESTEP_API_URL="http://127.0.0.1:${ACE_PORT}"
mkdir -p "$LOG_DIR"

pids=()
cleanup() {
    for pid in "${pids[@]:-}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

# ACE-Step binds loopback and runs without Gradio auth: @gradio/client cannot
# authenticate, and loopback keeps it off the public proxy regardless of which
# ports the pod exposes. Use ./start.sh instead if you want the Gradio UI.
if curl -sf "http://127.0.0.1:${ACE_PORT}/health" >/dev/null 2>&1; then
    echo "[start-ui] ACE-Step already running on ${ACE_PORT}"
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
    pids+=($!)

    echo -n "[start-ui] waiting for models to load (several minutes)"
    for _ in $(seq 1 180); do
        if curl -sf "http://127.0.0.1:${ACE_PORT}/health" >/dev/null 2>&1; then
            echo " ready"
            break
        fi
        if ! kill -0 "${pids[-1]}" 2>/dev/null; then
            echo
            echo "ERROR: ACE-Step exited. Last lines of $LOG_DIR/acestep.log:" >&2
            tail -20 "$LOG_DIR/acestep.log" >&2
            exit 1
        fi
        echo -n "."
        sleep 10
    done
fi

echo "[start-ui] starting Express backend on 127.0.0.1:3001 (log: $LOG_DIR/ui-server.log)"
cd "$UI_DIR/server"
nohup npx tsx src/index.ts > "$LOG_DIR/ui-server.log" 2>&1 &
pids+=($!)
sleep 5

echo "[start-ui] starting frontend on 0.0.0.0:${UI_PORT}"
echo
echo "  open  https://<POD_ID>-${UI_PORT}.proxy.runpod.net"
echo
cd "$UI_DIR"
exec npx vite --config vite.config.runpod.ts
