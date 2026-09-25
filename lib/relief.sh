#!/bin/bash
# Memory relief actions, ordered by how much they can cost you.
#
# Soft relief never terminates a process and runs automatically. Reclaiming a
# renderer terminates something, so it is always an explicit user action and is
# re-validated against the protection rules at the moment of the kill.

MEMGUARD_STATE_DIR="${MEMGUARD_STATE_DIR:-$HOME/.djaunt/memguard}"
RELIEF_STAMP_FILE="$MEMGUARD_STATE_DIR/last-relief"

memguard_log() {
  mkdir -p "$MEMGUARD_STATE_DIR"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$MEMGUARD_STATE_DIR/memguard.log"
}

# Tests the exact command, not a generic one. The sudoers rule grants only
# purge and the pressure sysctl, so `sudo -n true` fails even when relief works.
can_sudo_silently() { sudo -n -l "$1" >/dev/null 2>&1; }

relief_is_cooling_down() {
  [ -f "$RELIEF_STAMP_FILE" ] || return 1
  local last now
  last=$(cat "$RELIEF_STAMP_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ $((now - last)) -lt "${RELIEF_COOLDOWN_SECONDS:-300}" ]
}

# Drops the file cache. Frees inactive pages, loses no application state.
run_purge() {
  [ "${ENABLE_PURGE:-1}" = "1" ] || return 0
  if ! can_sudo_silently /usr/sbin/purge; then
    memguard_log "purge skipped: passwordless sudo not configured (run 'djt-memguard install-sudoers')"
    return 1
  fi
  local before after
  before=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
  sudo -n /usr/sbin/purge 2>/dev/null
  after=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
  memguard_log "purge freed $(awk -v a="$before" -v b="$after" \
    'BEGIN {printf "%.2f", (b - a) * 16384 / 1073741824}') GB"
}

# Signals critical pressure so apps voluntarily release their internal caches.
# Writes a kernel sysctl, so the reset is guarded by a trap and a watchdog.
# Disabled by default until exercised by hand.
run_pressure_pulse() {
  [ "${ENABLE_PRESSURE_PULSE:-0}" = "1" ] || return 0
  can_sudo_silently /usr/sbin/sysctl || { memguard_log "pressure pulse skipped: no passwordless sudo"; return 1; }

  reset_pressure() { sudo -n /usr/sbin/sysctl -w kern.memorypressure_manual_trigger=1 >/dev/null 2>&1; }
  trap reset_pressure EXIT INT TERM

  sudo -n /usr/sbin/sysctl -w kern.memorypressure_manual_trigger=4 >/dev/null 2>&1 \
    || { memguard_log "pressure pulse failed to set trigger"; trap - EXIT INT TERM; return 1; }
  sleep "${PRESSURE_PULSE_SECONDS:-3}"
  reset_pressure
  trap - EXIT INT TERM
  memguard_log "pressure pulse completed and reset to normal"
}

soft_relief() {
  mkdir -p "$MEMGUARD_STATE_DIR"
  memguard_log "soft relief starting"
  run_purge
  run_pressure_pulse
  date +%s > "$RELIEF_STAMP_FILE"
  memguard_log "soft relief done"
}

# Terminates one renderer, but only after re-confirming it is still a valid
# candidate. A PID can be recycled between listing and clicking.
reclaim_pid() {
  local target="$1"
  local line
  line=$(classify_processes | awk -F'|' -v p="$target" '$3 == p')

  if [ -z "$line" ]; then
    echo "pid $target no longer exists" >&2; return 1
  fi
  if [ "$(echo "$line" | cut -d'|' -f1)" != "CANDIDATE" ]; then
    echo "refusing: pid $target is protected or busy" >&2
    memguard_log "REFUSED reclaim of protected pid $target"
    return 1
  fi

  local freed_mb comm
  freed_mb=$(echo "$line" | awk -F'|' '{printf "%.0f", $2 / 1024}')
  comm=$(echo "$line" | cut -d'|' -f6)
  kill -TERM "$target" 2>/dev/null \
    && { memguard_log "reclaimed pid $target (${freed_mb} MB) $comm"; echo "reclaimed ${freed_mb} MB"; } \
    || { echo "failed to signal pid $target" >&2; return 1; }
}

# Reclaims safe candidates until the target is met. Never touches RISKY ones.
reclaim_safe_until() {
  local target_gb="$1" freed_kb=0
  while IFS='|' read -r status rss pid cpu risk comm; do
    [ "$risk" = "SAFE" ] || continue
    awk -v f="$freed_kb" -v t="$target_gb" 'BEGIN { exit !(f / 1048576 >= t) }' && break
    reclaim_pid "$pid" >/dev/null 2>&1 && freed_kb=$((freed_kb + rss))
  done < <(reclaim_candidates)
  awk -v f="$freed_kb" 'BEGIN { printf "%.2f", f / 1048576 }'
}
