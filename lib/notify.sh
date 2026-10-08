#!/bin/bash
# User-facing alerts. The menu bar carries the live state; these interrupt.
#
# A banner disappears in ~5 seconds and is silent under Focus, so CRITICAL also
# opens a dialog that stays until dismissed. Alerts repeat while the tier holds.

MEMGUARD_STATE_DIR="${MEMGUARD_STATE_DIR:-$HOME/.djaunt/memguard}"
LAST_ALERT_FILE="$MEMGUARD_STATE_DIR/last-alert"
DIALOG_PID_FILE="$MEMGUARD_STATE_DIR/dialog.pid"

applescript_quote() { local text="${1//\\/\\\\}"; printf '%s' "${text//\"/\\\"}"; }

notify() {
  local title="$1" message="$2" sound="${3:-}"
  local script="display notification \"$(applescript_quote "$message")\" with title \"$(applescript_quote "$title")\""
  [ -n "$sound" ] && script="$script sound name \"$sound\""
  osascript -e "$script" >/dev/null 2>&1
}

dialog_is_open() {
  [ -f "$DIALOG_PID_FILE" ] && kill -0 "$(cat "$DIALOG_PID_FILE" 2>/dev/null)" 2>/dev/null
}

# Runs in the background so the daemon keeps sampling while the dialog is up.
critical_dialog() {
  local message="$1"
  [ "${CRITICAL_DIALOG:-1}" = "1" ] || return 0
  dialog_is_open && return 0
  osascript -e "display alert \"Memory critical — act now\" message \"$(applescript_quote "$message")\" as critical giving up after 600" \
    >/dev/null 2>&1 &
  echo $! > "$DIALOG_PID_FILE"
}

alert_for_tier() {
  local tier_name="$1" reason="$2" reclaimable_gb="$3"
  case "$tier_name" in
    WARN)
      notify "Memory getting tight" \
        "$reason. Close tabs or reclaim ${reclaimable_gb} GB from the menu bar." "Submarine" ;;
    CRITICAL)
      local message="$reason. Reclaim ${reclaimable_gb} GB of idle tabs from the menu bar, or quit a browser."
      notify "Memory critical — act now" "$message" "Basso"
      critical_dialog "$message" ;;
  esac
  date +%s > "$LAST_ALERT_FILE"
}

notify_tier_change() {
  local tier_name="$1" reason="$2" reclaimable_gb="$3"
  if [ "$tier_name" = "OK" ]; then
    notify "Memory recovered" "Back to healthy."
    rm -f "$LAST_ALERT_FILE"
    return
  fi
  alert_for_tier "$tier_name" "$reason" "$reclaimable_gb"
}

realert_is_due() {
  [ -f "$LAST_ALERT_FILE" ] || return 0
  local last
  last=$(cat "$LAST_ALERT_FILE" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - last )) -ge "${REALERT_SECONDS:-600}" ]
}
