#!/usr/bin/env bash
# One-time setup on a RunPod pod with a network volume mounted at /workspace.
# Safe to re-run: it updates the checkout and re-syncs deps.
set -euo pipefail

VOL="${VOL:-/workspace}"
REPO_DIR="$VOL/ACE-Step-1.5"

if [[ ! -d "$VOL" ]]; then
    echo "ERROR: $VOL does not exist. Attach a network volume to this pod." >&2
    exit 1
fi

# uv lives in $HOME, which is on the ephemeral container disk, so it needs
# reinstalling on each new pod. The download is a few seconds.
if ! command -v uv &>/dev/null; then
    echo "[setup] installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# Everything expensive goes on the volume so it survives pod deletion.
export UV_CACHE_DIR="$VOL/uv-cache"
mkdir -p "$VOL/models" "$VOL/hf-cache" "$VOL/uv-cache" "$VOL/outputs"

if [[ -d "$REPO_DIR/.git" ]]; then
    echo "[setup] updating existing checkout..."
    git -C "$REPO_DIR" pull --ff-only
else
    echo "[setup] cloning ACE-Step-1.5..."
    git clone https://github.com/ace-step/ACE-Step-1.5.git "$REPO_DIR"
fi

# The venv is created inside REPO_DIR, i.e. on the volume, so deps persist too.
# uv fetches its own Python if the pod's is outside the 3.11-3.12 range.
echo "[setup] syncing dependencies (several minutes on first run)..."
cd "$REPO_DIR"
uv sync

echo
echo "[setup] done. Now run: ./start.sh"
