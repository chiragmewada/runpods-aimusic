#!/usr/bin/env bash
# Stop everything start-ui.sh leaves running, including the ACE-Step backend
# it deliberately keeps warm between UI restarts.
set -uo pipefail

stopped=0
for pattern in "vite --config vite.config.runpod" "tsx src/index.ts" "acestep"; do
    if pkill -f "$pattern" 2>/dev/null; then
        echo "[stop-ui] stopped: $pattern"
        stopped=1
    fi
done

[[ "$stopped" -eq 0 ]] && echo "[stop-ui] nothing was running"
exit 0
