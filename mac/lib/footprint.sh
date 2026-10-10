#!/bin/bash
# Physical footprint per process — the number macOS itself ranks by in the
# out-of-memory dialog, and what Activity Monitor's "Memory" column shows.
#
# Why not ps rss: rss counts only pages resident right now, so it silently
# omits compressed and swapped-out pages. Measured on this machine, one VS Code
# extension host read 485 MB by rss and 785 MB by footprint — a 38% undercount,
# exactly the pages that pressure is made of.
#
# /usr/bin/footprint -a requires root. `top -l 1 -stats mem` reports the same
# value unprivileged, so that is the source. It samples every process, so the
# result is cached rather than recomputed on every poll.

MEMGUARD_STATE_DIR="${MEMGUARD_STATE_DIR:-$HOME/.djaunt/memguard}"
FOOTPRINT_CACHE="$MEMGUARD_STATE_DIR/footprint.cache"
FOOTPRINT_CACHE_SECONDS="${FOOTPRINT_CACHE_SECONDS:-60}"

# Emits "<pid> <kb>" lines.
collect_footprints() {
  top -l 1 -stats pid,mem,command 2>/dev/null | awk '
    /^ *[0-9]+ / {
      size = $2
      suffix = substr(size, length(size), 1)
      if (suffix == "+" || suffix == "-") {
        size = substr(size, 1, length(size) - 1)
        suffix = substr(size, length(size), 1)
      }
      value = substr(size, 1, length(size) - 1) + 0
      if      (suffix == "G") kb = value * 1048576
      else if (suffix == "M") kb = value * 1024
      else if (suffix == "K") kb = value
      else                    kb = 0
      if (kb > 0) printf "%d %d\n", $1, kb
    }'
}

footprint_cache_is_stale() {
  [ -f "$FOOTPRINT_CACHE" ] || return 0
  local age=$(( $(date +%s) - $(stat -f %m "$FOOTPRINT_CACHE" 2>/dev/null || echo 0) ))
  [ "$age" -ge "$FOOTPRINT_CACHE_SECONDS" ]
}

refresh_footprint_cache() {
  local force="${1:-}"
  if [ "$force" = "force" ] || footprint_cache_is_stale; then
    mkdir -p "$MEMGUARD_STATE_DIR"
    collect_footprints > "$FOOTPRINT_CACHE.tmp" 2>/dev/null \
      && mv "$FOOTPRINT_CACHE.tmp" "$FOOTPRINT_CACHE"
  fi
  [ -f "$FOOTPRINT_CACHE" ] || : > "$FOOTPRINT_CACHE"
}
