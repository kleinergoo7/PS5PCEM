#!/bin/sh
# Build with Zig caches confined to /tmp and trimmed under a 5 GB cap.
set -eu

export ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-capped-global
local_cache=/tmp/opencode/zig-capped-local
cap_kb=5000000

cache_total_kb() {
    du -sk "$ZIG_GLOBAL_CACHE_DIR" "$local_cache" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'
}

/home/reng/tools/zig-x86_64-linux-0.16.0/zig build --cache-dir /tmp/opencode/zig-capped-local "$@"

total_kb=$(cache_total_kb)
echo "cache total: ${total_kb} KB"

if [ "$total_kb" -gt "$cap_kb" ]; then
    rm -rf "$local_cache"
    echo "cache trimmed"
    total_kb=$(cache_total_kb)
    echo "cache total: ${total_kb} KB"
    if [ "$total_kb" -gt "$cap_kb" ]; then
        echo "cache still over ${cap_kb} KB after trim" >&2
        exit 1
    fi
fi
