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
mkdir -p "$VOL/hf-cache" "$VOL/uv-cache" "$VOL/outputs"

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

# Earlier versions of these scripts set ACESTEP_CHECKPOINTS_DIR=$VOL/models,
# which the LM loader ignores. Move anything already downloaded into the path
# the app actually reads rather than making the user re-fetch several GB.
if [[ -d "$VOL/models" ]] && [[ -n "$(ls -A "$VOL/models" 2>/dev/null)" ]]; then
    echo "[setup] migrating models from $VOL/models to the default checkpoints dir..."
    mkdir -p "$REPO_DIR/checkpoints"
    for item in "$VOL/models"/*; do
        name="$(basename "$item")"
        if [[ -e "$REPO_DIR/checkpoints/$name" ]]; then
            echo "  skip $name (already present)"
        else
            mv "$item" "$REPO_DIR/checkpoints/$name"
            echo "  moved $name"
        fi
    done
    rmdir "$VOL/models" 2>/dev/null || true
fi

echo
echo "[setup] done. Now run: ./start.sh"
