#!/bin/bash
# Turns a probe snapshot into a stable OK / WARN / CRITICAL tier.
#
# Raw thresholds flap when the machine sits near a boundary, so the tier only
# moves after the same reading repeats. Escalation is deliberately faster than
# de-escalation: a late warning is useless, an early all-clear is misleading.

MEMGUARD_STATE_DIR="${MEMGUARD_STATE_DIR:-$HOME/.djaunt/memguard}"
TIER_STATE_FILE="$MEMGUARD_STATE_DIR/tier.state"

TIER_NAMES=(OK WARN CRITICAL)

# Float-safe "is $1 <= $2".
at_or_below() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }
at_or_above() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

# Reads probe vars from the environment. Echoes "<tier>|<reason>" because a
# command substitution would discard anything assigned to a variable here.
evaluate_raw_tier() {
  if [ "$PRESSURE_LEVEL" -ge 4 ] 2>/dev/null; then
    echo "2|kernel reports critical memory pressure"; return
  fi
  if [ "$LOAD_PCT" -ge "$CRIT_LOAD_PCT" ]; then
    echo "2|memory load ${LOAD_PCT}% of RAM (swap ${SWAP_USED_GB%.*} GB + compressor ${COMPRESSOR_GB%.*} GB)"; return
  fi
  if at_or_below "$FREE_PCT" "$CRIT_FREE_PCT"; then
    echo "2|only ${FREE_PCT}% memory free"; return
  fi
  # Swap grows into free disk. When the disk is gone, so is the last runway.
  if at_or_below "$DISK_FREE_GB" "$CRIT_DISK_FREE_GB"; then
    echo "2|only ${DISK_FREE_GB} GB disk left for swap to grow into"; return
  fi

  if [ "$LOAD_PCT" -ge "$WARN_LOAD_PCT" ]; then
    echo "1|memory load ${LOAD_PCT}% of RAM (swap ${SWAP_USED_GB%.*} GB + compressor ${COMPRESSOR_GB%.*} GB)"; return
  fi
  if at_or_below "$FREE_PCT" "$WARN_FREE_PCT"; then
    echo "1|${FREE_PCT}% memory free"; return
  fi
  if at_or_above "$SWAP_GROWTH_GB_PER_MIN" "$WARN_SWAP_GROWTH_GB_PER_MIN"; then
    echo "1|swap growing ${SWAP_GROWTH_GB_PER_MIN} GB/min"; return
  fi

  echo "0|healthy (load ${LOAD_PCT}%)"
}

# Applies hysteresis and persists the result.
# Sets TIER, TIER_NAME, PREVIOUS_TIER, TIER_CHANGED.
resolve_tier() {
  local evaluated raw raw_reason
  evaluated=$(evaluate_raw_tier)
  raw=${evaluated%%|*}
  raw_reason=${evaluated#*|}

  local current escalate deescalate
  CURRENT_TIER=0; ESCALATE_COUNT=0; DEESCALATE_COUNT=0
  # shellcheck disable=SC1090
  [ -f "$TIER_STATE_FILE" ] && . "$TIER_STATE_FILE"
  current=${CURRENT_TIER:-0}
  escalate=${ESCALATE_COUNT:-0}
  deescalate=${DEESCALATE_COUNT:-0}

  PREVIOUS_TIER=$current
  if [ "$raw" -gt "$current" ]; then
    escalate=$((escalate + 1)); deescalate=0
    if [ "$escalate" -ge "$ESCALATE_AFTER" ]; then current=$raw; escalate=0; fi
  elif [ "$raw" -lt "$current" ]; then
    deescalate=$((deescalate + 1)); escalate=0
    if [ "$deescalate" -ge "$DEESCALATE_AFTER" ]; then current=$raw; deescalate=0; fi
  else
    escalate=0; deescalate=0
  fi

  mkdir -p "$MEMGUARD_STATE_DIR"
  cat > "$TIER_STATE_FILE" <<STATE
CURRENT_TIER=$current
ESCALATE_COUNT=$escalate
DEESCALATE_COUNT=$deescalate
STATE

  TIER=$current
  TIER_NAME=${TIER_NAMES[$current]}
  RAW_TIER=$raw
  RAW_TIER_NAME=${TIER_NAMES[$raw]}
  REASON="$raw_reason"
  [ "$current" != "$PREVIOUS_TIER" ] && TIER_CHANGED=1 || TIER_CHANGED=0
}
