#!/usr/bin/env bash
# Stop everything start-ui.sh leaves running, including the ACE-Step backend
# it deliberately keeps warm between UI restarts.
set -uo pipefail

ACE_PORT="${ACE_PORT:-7861}"
UI_PORT="${UI_PORT:-7860}"

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# By port, not by command line: tsx and uv both run the real server in a child
# process whose arguments do not mention them, so pattern matching misses the
# process actually holding the socket.
kill_port() {
    local port="$1" label="$2" pids=""
    # `|| true` on each: grep exits 1 when the port is free, which would abort
    # a `set -e` script silently. stop-ui.sh does not set -e, but these are the
    # same lookups as start-ui.sh and should behave identically.
    pids=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u) || true
    if [[ -z "$pids" ]]; then
        pids=$(fuser -n tcp "$port" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$') || true
    fi
    if [[ -z "$pids" ]]; then
        pids=$(lsof -t -i ":$port" 2>/dev/null) || true
    fi
    if [[ -z "$pids" ]]; then
        echo "[stop-ui] $label (port $port): not running"
        return 0
    fi
    echo "[stop-ui] stopping $label (port $port): $(echo "$pids" | tr '\n' ' ')"
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    for _ in $(seq 1 20); do port_open "$port" || return 0; sleep 0.5; done
    for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
}

kill_port "$UI_PORT" "frontend"
kill_port 3001 "backend"
kill_port "$ACE_PORT" "ACE-Step"

# An ACE-Step that lost the race to bind the port still holds its models in
# VRAM, and killing by port alone never reaches it.
if pgrep -f "acestep --port" >/dev/null 2>&1; then
    echo "[stop-ui] stopping stray ACE-Step process(es)"
    pkill -f "acestep --port" 2>/dev/null || true
    sleep 3
    pkill -9 -f "acestep --port" 2>/dev/null || true
fi

# Generation runs in its own process; an OOM can leave it alive holding VRAM.
if pgrep -f "simple_generate.py" >/dev/null 2>&1; then
    echo "[stop-ui] stopping stray generation process(es)"
    pkill -9 -f "simple_generate.py" 2>/dev/null || true
fi

if command -v nvidia-smi >/dev/null 2>&1; then
    echo "[stop-ui] VRAM in use: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null)"
fi
exit 0
