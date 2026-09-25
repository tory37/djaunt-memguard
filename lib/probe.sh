#!/bin/bash
# Samples macOS memory state. Emits flat KEY=VALUE lines on stdout.
#
# The headline number in Activity Monitor is virtual size and is not a useful
# signal. What actually precedes the out-of-memory dialog is swap headroom
# collapsing while the compressor grows, so those are what we sample.

MEMGUARD_STATE_DIR="${MEMGUARD_STATE_DIR:-$HOME/.djaunt/memguard}"
SAMPLE_FILE="$MEMGUARD_STATE_DIR/samples"
SAMPLE_HISTORY_LINES=120

# vm.swapusage prints e.g. "total = 27648.00M  used = 26968.19M  free = 679.81M"
# Values carry a unit suffix that can be M or G depending on size.
parse_swap_field() {
  local raw="$1"
  echo "$raw" | awk '
    {
      value = $0
      unit = substr(value, length(value), 1)
      gsub(/[A-Za-z]$/, "", value)
      if (unit == "G") printf "%.3f", value
      else if (unit == "K") printf "%.3f", value / 1048576
      else printf "%.3f", value / 1024    # M is the common case
    }'
}

record_sample() {
  local epoch="$1" swap_used_gb="$2"
  mkdir -p "$MEMGUARD_STATE_DIR"
  echo "$epoch $swap_used_gb" >> "$SAMPLE_FILE"
  # Keep the file bounded; this runs every poll interval forever.
  if [ "$(wc -l < "$SAMPLE_FILE")" -gt "$SAMPLE_HISTORY_LINES" ]; then
    tail -n "$SAMPLE_HISTORY_LINES" "$SAMPLE_FILE" > "$SAMPLE_FILE.tmp" \
      && mv "$SAMPLE_FILE.tmp" "$SAMPLE_FILE"
  fi
}

# Swap growth over the last ~60s, in GB/min. Zero when there is no history yet.
swap_growth_per_min() {
  local now_epoch="$1" now_used="$2"
  [ -f "$SAMPLE_FILE" ] || { echo "0.00"; return; }
  awk -v now_epoch="$now_epoch" -v now_used="$now_used" '
    {
      age = now_epoch - $1
      if (age >= 45 && age <= 120 && (best_age == 0 || age < best_age)) {
        best_age = age; best_used = $2
      }
    }
    END {
      if (best_age == 0) { print "0.00"; exit }
      printf "%.2f", (now_used - best_used) * 60.0 / best_age
    }' "$SAMPLE_FILE"
}

memguard_probe() {
  local epoch pagesize pressure_level free_pct
  epoch=$(date +%s)
  pagesize=$(sysctl -n hw.pagesize)
  pressure_level=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 1)
  free_pct=$(sysctl -n kern.memorystatus_level 2>/dev/null || echo 100)

  local swap_line swap_total_gb swap_used_gb swap_free_gb
  swap_line=$(sysctl -n vm.swapusage)
  swap_total_gb=$(parse_swap_field "$(echo "$swap_line" | awk '{print $3}')")
  swap_used_gb=$(parse_swap_field  "$(echo "$swap_line" | awk '{print $6}')")
  swap_free_gb=$(parse_swap_field  "$(echo "$swap_line" | awk '{print $9}')")

  local compressor_gb wired_gb
  compressor_gb=$(vm_stat | awk -v ps="$pagesize" \
    '/occupied by compressor/ { gsub(/\./, "", $NF); printf "%.2f", $NF * ps / 1073741824 }')
  wired_gb=$(vm_stat | awk -v ps="$pagesize" \
    '/Pages wired down/ { gsub(/\./, "", $NF); printf "%.2f", $NF * ps / 1073741824 }')

  local growth
  growth=$(swap_growth_per_min "$epoch" "$swap_used_gb")
  record_sample "$epoch" "$swap_used_gb"

  # Swap can grow while the boot disk has room, so disk headroom bounds how
  # much runway is actually left.
  local disk_free_gb
  disk_free_gb=$(df -g / | awk 'NR==2 {print $4}')

  cat <<PROBE
EPOCH=$epoch
PRESSURE_LEVEL=$pressure_level
FREE_PCT=$free_pct
SWAP_TOTAL_GB=$swap_total_gb
SWAP_USED_GB=$swap_used_gb
SWAP_FREE_GB=$swap_free_gb
SWAP_GROWTH_GB_PER_MIN=$growth
COMPRESSOR_GB=$compressor_gb
WIRED_GB=$wired_gb
DISK_FREE_GB=$disk_free_gb
PROBE
}
