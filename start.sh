#!/usr/bin/env bash
# Launch the ACE-Step Gradio UI for access via RunPod's HTTP proxy.
set -euo pipefail

VOL="${VOL:-/workspace}"
REPO_DIR="$VOL/ACE-Step-1.5"

if [[ ! -d "$REPO_DIR/.venv" ]]; then
    echo "ERROR: no venv at $REPO_DIR. Run ./setup.sh first." >&2
    exit 1
fi

# The proxy URL is public to anyone who learns the pod ID, so the UI is not
# started without credentials.
if [[ -z "${UI_USER:-}" || -z "${UI_PASS:-}" ]]; then
    echo "ERROR: set UI_USER and UI_PASS before starting." >&2
    echo "  export UI_USER=admin UI_PASS='<something-long>'" >&2
    exit 1
fi

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
# Deliberately NOT setting ACESTEP_CHECKPOINTS_DIR. The LM loader at
# acestep_v15_pipeline.py:546 hardcodes <project_root>/checkpoints and ignores
# that variable, so pointing it elsewhere makes the DiT and the LM resolve to
# different directories and the LM silently fails to load. The checkout already
# lives on the volume, so the default path persists anyway.
export HF_HOME="$VOL/hf-cache"
export UV_CACHE_DIR="$VOL/uv-cache"
export TOKENIZERS_PARALLELISM=false

cd "$REPO_DIR"

# Bypasses start_gradio_ui.sh, which blocks on an interactive update prompt
# and defaults to binding 127.0.0.1.
exec uv run --no-sync acestep \
    --port "${PORT:-7860}" \
    --server-name 0.0.0.0 \
    --language en \
    --config_path "${DIT_MODEL:-acestep-v15-turbo}" \
    --lm_model_path "${LM_MODEL:-acestep-5Hz-lm-1.7B}" \
    --init_service true \
    --auth-username "$UI_USER" \
    --auth-password "$UI_PASS"
