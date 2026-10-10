# Djaunt MemGuard

Early warning and safe relief for memory exhaustion, so the "your system has
run out of application memory" dialog stops being the first notice you get.

Site: https://tory37.github.io/djaunt-memguard/

## Platforms

| Folder | Platform | Status |
| --- | --- | --- |
| [`mac/`](mac/) | macOS | supported: launch agent, CLI, native menu bar app |

Each platform lives in its own top-level folder with its own probe, tiers, and
UI. The approach carries over between operating systems; the signals do not.

## Layout

```
mac/     macOS source, install steps, and docs (start with mac/README.md)
docs/    GitHub Pages site
```
