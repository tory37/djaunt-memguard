#!/bin/bash
# Shared bootstrap: resolves paths, loads config, sources the libraries.

MEMGUARD_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEMGUARD_STATE_DIR="${MEMGUARD_STATE_DIR:-$HOME/.djaunt/memguard}"
STATE_JSON="$MEMGUARD_STATE_DIR/state.json"
PAUSE_FILE="$MEMGUARD_STATE_DIR/paused-until"

mkdir -p "$MEMGUARD_STATE_DIR"

# Shipped defaults first, then the user's overrides if present.
# shellcheck disable=SC1091
. "$MEMGUARD_HOME/config.env"
# shellcheck disable=SC1091
[ -f "$MEMGUARD_STATE_DIR/config.env" ] && . "$MEMGUARD_STATE_DIR/config.env"

# shellcheck disable=SC1091
. "$MEMGUARD_HOME/lib/probe.sh"
# shellcheck disable=SC1091
. "$MEMGUARD_HOME/lib/tier.sh"
# shellcheck disable=SC1091
. "$MEMGUARD_HOME/lib/footprint.sh"
# shellcheck disable=SC1091
. "$MEMGUARD_HOME/lib/protect.sh"
# shellcheck disable=SC1091
. "$MEMGUARD_HOME/lib/relief.sh"
# shellcheck disable=SC1091
. "$MEMGUARD_HOME/lib/notify.sh"
# shellcheck disable=SC1091
. "$MEMGUARD_HOME/lib/recorder.sh"

is_paused() {
  [ -f "$PAUSE_FILE" ] || return 1
  local until_epoch
  until_epoch=$(cat "$PAUSE_FILE" 2>/dev/null || echo 0)
  [ "$(date +%s)" -lt "$until_epoch" ]
}

reclaimable_total_gb() {
  reclaim_candidates | awk -F'|' '{s += $2} END {printf "%.2f", s / 1048576}'
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Snapshot the daemon's view for the menu bar app to read.
write_state_json() {
  local tmp="$STATE_JSON.tmp"
  {
    printf '{\n'
    printf '  "epoch": %s,\n' "$EPOCH"
    printf '  "tier": %s,\n' "$TIER"
    printf '  "tier_name": "%s",\n' "$TIER_NAME"
    printf '  "reason": "%s",\n' "$(json_escape "$REASON")"
    printf '  "free_pct": %s,\n' "$FREE_PCT"
    printf '  "load_pct": %s,\n' "$LOAD_PCT"
    printf '  "mem_total_gb": %s,\n' "$MEM_TOTAL_GB"
    printf '  "pressure_level": %s,\n' "$PRESSURE_LEVEL"
    printf '  "swap_used_gb": %s,\n' "$SWAP_USED_GB"
    printf '  "swap_free_gb": %s,\n' "$SWAP_FREE_GB"
    printf '  "swap_growth_gb_per_min": %s,\n' "$SWAP_GROWTH_GB_PER_MIN"
    printf '  "compressor_gb": %s,\n' "$COMPRESSOR_GB"
    printf '  "wired_gb": %s,\n' "$WIRED_GB"
    printf '  "disk_free_gb": %s,\n' "$DISK_FREE_GB"
    printf '  "paused": %s,\n' "$(is_paused && echo true || echo false)"
    printf '  "reclaimable_gb": %s,\n' "$(reclaimable_total_gb)"
    printf '  "candidates": [\n'
    reclaim_candidates | head -14 | awk -F'|' '
      BEGIN { first = 1 }
      {
        label = $6
        sub(/.*\//, "", label)
        app = "Other"
        if ($6 ~ /Google Chrome/) app = "Chrome"
        else if ($6 ~ /Firefox/) app = "Firefox"
        else if ($6 ~ /Visual Studio Code/) app = "VS Code"
        else if ($6 ~ /Cursor/) app = "Cursor"
        else if ($6 ~ /Slack/) app = "Slack"
        else if ($6 ~ /Discord/) app = "Discord"
        else if ($6 ~ /Spotify/) app = "Spotify"
        if (!first) printf ",\n"
        first = 0
        printf "    {\"pid\": %s, \"mb\": %.0f, \"app\": \"%s\", \"risk\": \"%s\"}", $3, $2 / 1024, app, $5
      }
      END { printf "\n" }'
    printf '  ]\n}\n'
  } > "$tmp" && mv "$tmp" "$STATE_JSON"
}
