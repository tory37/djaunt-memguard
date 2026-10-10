#!/bin/bash
# Black box recorder.
#
# The out-of-memory dialog names a culprit, but by the time you read it nothing
# is measuring, so the claim can never be checked. On every escalation this
# writes a timestamped snapshot ranked by physical footprint — the same metric
# the dialog ranks by — so the next incident leaves evidence behind.

MEMGUARD_STATE_DIR="${MEMGUARD_STATE_DIR:-$HOME/.djaunt/memguard}"
INCIDENT_DIR="$MEMGUARD_STATE_DIR/incidents"
INCIDENT_KEEP=40

record_incident() {
  local tier_name="$1" reason="$2"
  mkdir -p "$INCIDENT_DIR"
  local stamp file
  stamp=$(date '+%Y%m%d-%H%M%S')
  file="$INCIDENT_DIR/$stamp-$tier_name.txt"

  # Force a fresh sample; a cached one could be up to a minute stale.
  refresh_footprint_cache force

  {
    echo "Djaunt MemGuard incident"
    echo "when    $(date '+%Y-%m-%d %H:%M:%S')"
    echo "tier    $tier_name"
    echo "reason  $reason"
    echo
    echo "free ${FREE_PCT}%  pressure ${PRESSURE_LEVEL}  swap ${SWAP_USED_GB} GB used"
    echo "swap growth ${SWAP_GROWTH_GB_PER_MIN} GB/min  compressor ${COMPRESSOR_GB} GB"
    echo "wired ${WIRED_GB} GB  boot disk free ${DISK_FREE_GB} GB"
    echo
    echo "=== by application (physical footprint) ==="
    classify_processes | awk -F'|' '
      {
        app = "other"
        if      ($6 ~ /Code Helper|Visual Studio Code/) app = "VS Code"
        else if ($6 ~ /Cursor/)                         app = "Cursor"
        else if ($6 ~ /Google Chrome/)                  app = "Chrome"
        else if ($6 ~ /[Ff]irefox|plugin-container/)    app = "Firefox"
        else if ($6 ~ /claude/)                         app = "claude agents"
        else if ($6 ~ /Slack/)                          app = "Slack"
        else if ($6 ~ /Discord/)                        app = "Discord"
        else if ($6 ~ /Virtualization|qemu|docker/)     app = "VMs"
        else if ($6 ~ /node/)                           app = "node"
        total[app] += $2; count[app]++
      }
      END { for (a in total) printf "%9.2f GB  %-14s (%d procs)\n", total[a] / 1048576, a, count[a] }' \
      | sort -rn
    echo
    echo "=== 25 largest processes ==="
    classify_processes | sort -t'|' -k2,2nr | head -25 | awk -F'|' '
      { label = $6; sub(/.*\//, "", label)
        printf "%8.0f MB  %-9s pid %-7s %s\n", $2 / 1024, $1, $3, label }'
    echo
    echo "=== reclaimable at this moment ==="
    reclaim_candidates | awk -F'|' '{ s += $2 } END { printf "%.2f GB across %d idle renderers\n", s / 1048576, NR }'
  } > "$file"

  memguard_log "incident recorded: $file"

  # Keep the directory bounded.
  ls -1t "$INCIDENT_DIR" 2>/dev/null | tail -n +$((INCIDENT_KEEP + 1)) \
    | while read -r old; do rm -f "$INCIDENT_DIR/$old"; done
}
