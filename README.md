# DiskScanHelpers

> Disk cleanup helpers for Xcode users — find what's eating your storage and clean it up safely.

Xcode caches (DerivedData, simulators, archives, device support) can quietly grow to dozens of gigabytes. These two small macOS scripts help you see exactly what's taking space and clean it up — with interactive HTML reports you open in your browser.

No dependencies beyond what ships with macOS (`bash`, `du`, `python3`).

---

## xcode_disk_scan — Xcode Disk Scan

Scans Xcode-related cache/data folders, prints sizes, and suggests cleanup actions split by **safety tier**.

### Usage

```bash
bash xcode_disk_scan.sh
```

Opens `Result/xcode_report.html` automatically.

### What it shows

- **DerivedData** — build caches per project, sorted by size
- **DeviceSupport** — debug symbols per iOS/watchOS/tvOS version
- **Simulators** — devices with name, runtime, size, status; orphaned devices flagged
- **Runtimes** — CoreSimulator runtime images
- **Archives** — shipped builds with app name, date, size; supports custom archive locations
- **Caches** — Xcode app cache, SwiftPM caches (system + user), Interface Builder cache
- Tiered summary: **Safe to delete** vs **Needs review** with separate totals
- Recommended commands grouped by safety tier

### Safety tiers

**✅ Safe tier (run anytime):**
- **DerivedData** — fully safe. Xcode rebuilds on next project open.
- **DeviceSupport** — safe. Xcode re-downloads on next device connect.
- **Orphan simulators** — `xcrun simctl delete unavailable` is always safe.
- **Caches** — regenerated on use.

**⚠️ Review tier (read notes first):**
- **Runtimes** — remove via Xcode → Settings → Platforms. Don't delete files directly.
- **Archives** — manage via Xcode → Organizer. Keep the latest per shipped version (dSYMs for crash symbolication).

Read-only — **nothing is deleted unless you copy a command and run it yourself.**

---

## disk_scan — General Disk Usage Report

Visual disk usage analyzer that generates an interactive HTML report for any folder. Useful for hunting storage hogs outside Xcode too.

### Files

| File | Purpose |
|---|---|
| `disk_scan.sh` | Main script — scans disk, builds data, generates report |
| `disk_report_template.html` | HTML template (never modified by the script) |
| `Result/disk_report.html` | Generated report with embedded data |

### Usage

```bash
bash disk_scan.sh [directory] [depth]
```

- **directory** — path to scan (default: `$HOME`)
- **depth** — how many levels deep (default: `3`)

Examples:
```bash
bash disk_scan.sh                          # scan $HOME, depth 3
bash disk_scan.sh ~ 4                      # scan $HOME, depth 4 (more detail)
bash disk_scan.sh /Users/me/Projects 2     # scan specific folder, depth 2
bash disk_scan.sh / 2                      # whole disk, shallow
```

### How it works

1. Runs `du` to collect directory sizes
2. Embedded Python builds a tree structure from the `du` output
3. Injects the JSON data into the HTML template
4. Saves the result to `Result/disk_report.html` and opens it

The template is never modified — data is injected into a copy. Re-running the script overwrites the previous result.

### Visualization

Three switchable views (canvas-based):

- **Sunburst** — concentric rings with percentage labels; inner = top-level, outer = deeper levels
- **Partition** — columnar layout showing parent→child hierarchy with colored backgrounds and separator lines
- **BoxMap** — nested treemap with proportional rectangles

All views support:
- Click to drill into a folder, breadcrumb / back to navigate up
- Hover tooltip with name, path, size, and percentage
- Interactive stacked bar and legend (click to drill in)

Sidebar:
- Sortable folder table with size bars
- Search/filter with "Only Top Folders" toggle (unchecked = search all levels)
- Click any row to drill into that folder

---

## Installation

Clone the repo and run the script you need — no install steps, no dependencies to download:

```bash
git clone https://github.com/Dimajp/DiskScanHelpers.git
cd DiskScanHelpers
bash xcode_disk_scan.sh   # or disk_scan.sh
```

## Requirements

- macOS (uses `du -d` flag and Xcode-specific paths)
- `python3` (ships with modern macOS)
- A browser to view the report

## Output

Each script generates a self-contained HTML file under `Result/`. The report opens automatically in your default browser.

---

## License

Released under the **MIT License**. See the [LICENSE](LICENSE) file for details.

Copyright © 2026 Dmitry Protopopov (github.com/Dimajp).
