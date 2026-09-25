#!/bin/bash
# User-facing alerts. Notifications only; the menu bar carries the live state.

notify() {
  local title="$1" message="$2" sound="${3:-}"
  local script="display notification \"${message//\"/\\\"}\" with title \"${title//\"/\\\"}\""
  [ -n "$sound" ] && script="$script sound name \"$sound\""
  osascript -e "$script" >/dev/null 2>&1
}

notify_tier_change() {
  local tier_name="$1" reason="$2" reclaimable_gb="$3"
  case "$tier_name" in
    WARN)
      notify "Memory getting tight" \
        "$reason. ${reclaimable_gb} GB reclaimable from idle tabs." "Submarine" ;;
    CRITICAL)
      notify "Memory critical — act now" \
        "$reason. Click the menu bar meter to reclaim ${reclaimable_gb} GB." "Basso" ;;
    OK)
      notify "Memory recovered" "Back to healthy." ;;
  esac
}
