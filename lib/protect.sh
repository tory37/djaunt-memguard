#!/bin/bash
# Classifies every running process as PROTECTED or a reclaim CANDIDATE.
#
# The safety rule that matters: agents, dev servers, builds, and SSH sessions
# all live inside a shell subtree, because an editor's integrated terminal
# spawns them under its pty host. Verified ancestry on this machine:
#   claude -> /bin/zsh -> Code Helper (pty host) -> Code
# So marking every shell subtree protected covers all of them structurally,
# with no name list to keep up to date. Candidates are only ever GUI renderer
# processes, which restore themselves when the window is next focused.
#
# Emits: STATUS|RSS_KB|PID|CPU|RISK|COMM

classify_processes() {
  local idle_cpu_max="${CANDIDATE_IDLE_CPU_MAX:-5.0}"
  local min_rss_mb="${CANDIDATE_MIN_RSS_MB:-100}"

  refresh_footprint_cache

  # First file is the footprint cache, second is the process table.
  awk \
    -v idle_cpu_max="$idle_cpu_max" \
    -v min_rss_kb="$((min_rss_mb * 1024))" \
    -v me="$(id -u)" '
    FNR == NR { footprint[$1] = $2; next }
    {
      pid = $1; ppid[$1] = $2; uid[$1] = $3; cpu[$1] = $4
      # Footprint where we have it; rss is the fallback and undercounts.
      rss[pid] = (pid in footprint) ? footprint[pid] : $5
      command = $6
      for (i = 7; i <= NF; i++) command = command " " $i
      comm[pid] = command
      pids[++count] = pid

      basename = command
      sub(/.*\//, "", basename)

      # Shell and terminal subtrees propagate protection to all descendants.
      is_shell = (basename ~ /^-?(zsh|bash|sh|fish|csh|tcsh|ksh)$/ || basename == "login")
      is_terminal_app = (command ~ /(Terminal|iTerm|Ghostty|Warp|Alacritty|kitty|WezTerm)\.app/ \
                         || basename ~ /^(tmux|screen|sshd)$/)
      if (is_shell || is_terminal_app) propagating_root[pid] = 1

      # Named workloads worth protecting even if launched outside a shell.
      if (basename ~ /^(claude|node|bun|deno|python|python3|ruby|java|go|cargo|rustc|ssh|mosh|git|docker|dockerd|colima|qemu.*|ollama|Xcode|mysqld|postgres|redis-server)$/)
        self_protect[pid] = 1

      if ($3 == 0 || $1 < 500) self_protect[pid] = 1
    }
    END {
      for (i = 1; i <= count; i++) {
        pid = pids[i]

        protected = self_protect[pid] || propagating_root[pid]

        # Walk up to the root looking for a shell or terminal ancestor.
        if (!protected) {
          ancestor = ppid[pid]
          hops = 0
          while (ancestor > 1 && hops < 40) {
            if (propagating_root[ancestor]) { protected = 1; break }
            if (!(ancestor in ppid)) break
            ancestor = ppid[ancestor]
            hops++
          }
        }

        command = comm[pid]
        risk = "SAFE"

        # Chromium/Electron tab renderers and Firefox content processes both
        # restore on next click. Extension hosts (Helper (Plugin)) are excluded
        # here by construction, since they hold editor extension state.
        reclaimable = (command ~ /Helper \(Renderer\)/ || command ~ /plugin-container/)
        if (command ~ /(Visual Studio Code|Cursor|Code - Insiders)/) risk = "RISKY"

        status = "PROTECTED"
        if (!protected && reclaimable && uid[pid] == me \
            && cpu[pid] + 0 <= idle_cpu_max + 0 && rss[pid] + 0 >= min_rss_kb + 0)
          status = "CANDIDATE"

        printf "%s|%d|%d|%.1f|%s|%s\n", status, rss[pid], pid, cpu[pid], risk, command
      }
    }' "$FOOTPRINT_CACHE" <(ps -Axo pid=,ppid=,uid=,pcpu=,rss=,comm=)
}

# Candidates ranked by how much they give back, with risky ones sorted last.
reclaim_candidates() {
  classify_processes | awk -F'|' '$1 == "CANDIDATE"' \
    | sort -t'|' -k5,5r -k2,2nr
}
