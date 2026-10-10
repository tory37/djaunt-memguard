# Djaunt MemGuard for macOS

Early warning and safe relief for macOS memory exhaustion, so the
"your system has run out of application memory" dialog stops being the first
notice you get.

## Why the usual numbers lie

Two measurements look alarming and mean nothing:

- **The multi-hundred-GB figure for VS Code is virtual address space**, not
  memory in use. Measured here: one VS Code extension host reserved **1,837 GB
  of virtual space against a 781 MB physical footprint** — a ratio of ~2,400:1.
  That is V8 reserving address space for its pointer-compression cage. It is a
  promise to the allocator, not memory, and it cannot "fill up": arm64 gives
  every process a 128 TB address space. The decisive comparison is that Chrome
  reserves **89 TB** of virtual space to VS Code's **66 TB** and is never
  blamed for it.
- **Swap "free" sits near zero on a healthy Mac.** The kernel keeps the swap
  file near capacity and grows it on demand. Measured here: 0.7 GB free while
  total grew 27 → 28 GB.

What actually moves ahead of an out-of-memory event, and what Djaunt MemGuard watches:

| Signal | Source |
| --- | --- |
| **Memory load** — swap used + compressor, as % of RAM | `vm.swapusage`, `vm_stat`, `hw.memsize` |
| Free memory percentage (backstop only) | `kern.memorystatus_level` |
| Kernel pressure level | `kern.memorystatus_vm_pressure_level` |
| Swap growth rate | `vm.swapusage` sampled over ~60s |
| Compressor size | `vm_stat` |
| Boot disk headroom | swap cannot grow past it |

## Measure footprint, never rss

The out-of-memory dialog ranks applications by **physical footprint**, the same
number Activity Monitor's "Memory" column shows. `ps rss` is not that number:
it counts only pages resident right now and omits compressed and swapped-out
pages — precisely the pages that pressure is made of.

Measured on one VS Code extension host:

| Source | Reading |
| --- | --- |
| `footprint -p` | 785 MB |
| `top -stats mem` | 785 MB |
| `ps rss` | 485 MB (38% low) |

Building per-app totals from rss understates VS Code by roughly 3x. Djaunt
MemGuard ranks everything by footprint, collected via `top` because
`footprint -a` requires root.

## Safety: agents are never touched

Verified process ancestry for a running agent:

```
claude -> /bin/zsh -> Code Helper (pty host) -> Code
```

Every agent, dev server, build, and SSH session lives inside a shell subtree.
Djaunt MemGuard marks **all shell subtrees protected**, so agents are excluded
structurally rather than by a name list that could fall out of date.

Reclaim candidates are only ever idle GUI renderer processes
(`Helper (Renderer)`, `plugin-container`), which restore themselves when the
window is next focused. Editor extension hosts (`Helper (Plugin)`) are excluded
because they hold extension state.

Additional guarantees:

- Automatic relief **never terminates anything**. Kills are always one explicit
  click, and the target is re-validated against the protection rules at the
  moment of the kill.
- VS Code and Cursor renderers are flagged `RISKY` and sorted last.
- Processes above the idle CPU threshold, root-owned processes, and PIDs below
  500 are never candidates.

## Tiers

| Tier | Enters when any holds |
| --- | --- |
| WARN | load ≥ 120%, free ≤ 10%, or swap growing ≥ 1.5 GB/min |
| CRITICAL | load ≥ 130%, free ≤ 5%, kernel pressure critical, or boot disk ≤ 15 GB |

Escalates after 2 consecutive samples (~20s), de-escalates after 30 (~5 min).
A late warning is useless; an early all-clear is misleading.

Why load and not free %: across 41 recorded incidents `kern.memorystatus_level`
read 33–62% "free", including three minutes before an out-of-memory dialog. It
counts compressible pages as free. Load read 131–137% in the 30 minutes before
that dialog, and ~104% after recovery.

Alerts: WARN posts a banner. CRITICAL posts a banner and opens a dialog that
stays until dismissed. Both repeat every 10 minutes while the tier holds.

## Relief ladder

1. **`purge`** — off by default (`ENABLE_PURGE=0`). Drops only the file cache.
   Pressure on this machine is anonymous app memory (compressed and swapped),
   which purge cannot free, and the cache refills in minutes. Kept as a manual
   menu item.
2. **Pressure pulse** — opt-in, `ENABLE_PRESSURE_PULSE=0` by default. Signals
   critical pressure for ~3s so apps release internal caches, then resets.
   Writes a kernel sysctl, so it ships disabled until tested by hand.
3. **Reclaim idle tabs** — manual click only. This is the action that
   actually frees memory. "Reclaim ~4 GB of idle tabs now" is the top item.

## Install

Run from this `mac/` folder.

```bash
./bin/djt-memguard install          # builds the menu bar app, loads both launch agents
./bin/djt-memguard install-sudoers  # optional: allows passwordless purge
```

Optionally put it on your PATH:

```bash
ln -s "$PWD/bin/djt-memguard" /usr/local/bin/djt-memguard
```

`install-sudoers` grants exactly two commands and nothing else:

```
<you> ALL=(root) NOPASSWD: /usr/sbin/purge, /usr/sbin/sysctl -w kern.memorypressure_manual_trigger=*
```

The menu bar app is compiled with the system `swiftc`. No Homebrew, no
SwiftBar, no dependencies.

## Commands

```
djt-memguard status             current tier and all metrics
djt-memguard top                what is reclaimable, and what is protected
djt-memguard relief             drop the file cache (does not free app memory)
djt-memguard reclaim <pid>      terminate one idle renderer, re-checked first
djt-memguard reclaim --safe [gb] reclaim SAFE candidates until ~gb is freed (default 4)
djt-memguard pause [minutes]    silence relief and alerts
djt-memguard log [lines]        recent activity
djt-memguard uninstall          unload and remove the launch agents
```

## Menu bar

The item labels itself with memory load — `● MEM 104%` — so it is identifiable at a glance
without clicking. Shape carries the tier alongside colour, so it still reads if
colour does not: `●` green OK, `◆` orange WARN, `▲` red CRITICAL, `◐` paused.

The menu carries live metrics, a soft-relief button, a ranked reclaim submenu
showing the app and megabytes for each candidate, and links to the log and the
incident snapshots.

## Black box recorder

The out-of-memory dialog names a culprit, but nothing is measuring when it
appears, so the claim can never be checked. On every escalation Djaunt MemGuard
writes a timestamped snapshot to `~/.djaunt/memguard/incidents/`, ranked by
physical footprint: per-application totals, the 25 largest processes with their
protected/candidate status, and how much was reclaimable at that instant.

After the next near-miss there is evidence instead of a guess.

## Layout

```
bin/djt-memguard    CLI
bin/djt-memguardd   daemon (poll, tier, notify, soft relief)
lib/probe.sh        memory sampling
lib/tier.sh         thresholds and hysteresis
lib/protect.sh      protection and candidate classification
lib/relief.sh       purge, pressure pulse, guarded reclaim
lib/notify.sh       notifications
menubar/            Swift NSStatusItem app
config.env          thresholds; override at ~/.djaunt/memguard/config.env
```

State, logs, and the published `state.json` live in `~/.djaunt/memguard/`.
