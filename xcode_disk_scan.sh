#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  xcode_disk_scan.sh  —  Xcode Disk Scan (v2)
#  Usage:  bash xcode_disk_scan.sh
#  Scans Xcode-related cache/data folders and generates
#  an HTML report in Result/xcode_report.html
# ─────────────────────────────────────────────

XCODE_DEV="$HOME/Library/Developer/Xcode"
CORE_SIM="$HOME/Library/Developer/CoreSimulator"
DEVICES_DIR="$CORE_SIM/Devices"
CACHES_DIR="$HOME/Library/Caches"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "🔧 Xcode Cleanup Helper — scanning…"

python3 - "$XCODE_DEV" "$DEVICES_DIR" "$CACHES_DIR" "$SCRIPT_DIR" <<'PYEOF'
import os, sys, re, subprocess, shlex, json

xcode_dev    = sys.argv[1]
devices_dir  = sys.argv[2]
caches_dir   = sys.argv[3]
script_dir   = sys.argv[4]

# JSON report data
report = {
    "scan_date": "",
    "safe_total": 0,
    "review_total": 0,
    "derived_data": None,
    "device_support": None,
    "simulators": None,
    "runtimes": None,
    "archives": None,
    "caches": None,
    "actions": []
}

import datetime
report["scan_date"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")

# ──────────────────────────────────────────────
#  HELPERS
# ──────────────────────────────────────────────
def fmt(b):
    if b >= 1073741824: return f"{b/1073741824:.1f} GB"
    if b >= 1048576:    return f"{b/1048576:.1f} MB"
    if b >= 1024:       return f"{b/1024:.1f} KB"
    return f"{b} B"

def du_children(parent):
    """Return [(name, bytes), ...] for direct subdirs of `parent`. Fast — one du call."""
    if not os.path.isdir(parent):
        return []
    subdirs = [os.path.join(parent, e) for e in os.listdir(parent)
               if os.path.isdir(os.path.join(parent, e))]
    if not subdirs:
        return []
    try:
        out = subprocess.check_output(
            ["du", "-sk"] + subdirs,
            text=True, stderr=subprocess.DEVNULL
        )
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        try:
            kb = int(parts[0])
        except ValueError:
            continue
        name = os.path.basename(parts[1].rstrip("/"))
        rows.append((name, kb * 1024))
    return rows

def du_total(path):
    """Total bytes for a single path."""
    if not os.path.isdir(path):
        return 0
    try:
        out = subprocess.check_output(["du", "-sk", path], text=True, stderr=subprocess.DEVNULL)
        return int(out.split()[0]) * 1024
    except Exception:
        return 0

def parse_version(name):
    m = re.match(r"(\d+)\.(\d+)", name)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)

# Tiered totals
safe_total   = 0   # always safe to delete
review_total = 0   # needs review (archives, runtimes)

# ──────────────────────────────────────────────
#  1. DerivedData  (safe)
# ──────────────────────────────────────────────
derived_dir = os.path.join(xcode_dev, "DerivedData")
derived_total = 0
dd_items = []
if os.path.isdir(derived_dir):
    entries = du_children(derived_dir)
    derived_total = sum(s for _, s in entries)
    safe_total += derived_total
    entries.sort(key=lambda e: e[1], reverse=True)

    for name, size in entries:
        display = re.sub(r"-[a-z]{20,}$", "", name)
        dd_items.append({"name": display, "bytes": size})

report["derived_data"] = {"total": derived_total, "items": dd_items}

# ──────────────────────────────────────────────
#  2. DeviceSupport  (safe)
# ──────────────────────────────────────────────
platforms = [
    ("iOS DeviceSupport", "iOS"),
    ("watchOS DeviceSupport", "watchOS"),
    ("tvOS DeviceSupport", "tvOS"),
]
ds_found = False
ds_total = 0
ds_items = []

for folder_name, label in platforms:
    support_dir = os.path.join(xcode_dev, folder_name)
    if not os.path.isdir(support_dir):
        continue
    entries = du_children(support_dir)
    if not entries:
        continue
    ds_found = True
    platform_total = sum(s for _, s in entries)
    ds_total += platform_total
    entries.sort(key=lambda e: parse_version(e[0]), reverse=True)

    for name, size in entries:
        ds_items.append({"name": name, "platform": label, "bytes": size})

if ds_found:
    safe_total += ds_total

report["device_support"] = {"total": ds_total, "items": ds_items}

# ──────────────────────────────────────────────
#  3. Simulator Devices  (mostly safe)
# ──────────────────────────────────────────────
sim_total = 0
sim_rows = []
unavail_bytes = 0
unavail_count = 0
avail_count = 0

if os.path.isdir(devices_dir):
    # Device info from simctl
    try:
        out = subprocess.check_output(["xcrun", "simctl", "list", "devices"], text=True)
    except Exception:
        out = ""

    device_info = {}
    current_runtime = ""
    for line in out.splitlines():
        m = re.match(r"^-- (.+) --$", line.strip())
        if m:
            current_runtime = m.group(1)
            continue
        # UUIDs can be upper or lowercase
        m = re.match(r"^\s+(.+?)\s+\(([A-Fa-f0-9-]{36})\)\s+\(([^)]+)\)", line)
        if m:
            name, uuid, state = m.group(1), m.group(2).upper(), m.group(3)
            device_info[uuid] = {"name": name, "runtime": current_runtime, "state": state}

    # Unavailable set — pulled from JSON for reliability
    unavailable = set()
    try:
        js = subprocess.check_output(
            ["xcrun", "simctl", "list", "devices", "--json"], text=True
        )
        parsed = json.loads(js)
        for runtime_id, devs in parsed.get("devices", {}).items():
            # Runtimes that no longer exist contain "unavailable" in the key
            is_unavail_runtime = "unavailable" in runtime_id.lower()
            for d in devs:
                if is_unavail_runtime or not d.get("isAvailable", True):
                    unavailable.add(d["udid"].upper())
    except Exception:
        pass

    # Single du call for all devices = fast
    rows = du_children(devices_dir)
    for uuid_dir, size_bytes in rows:
        uuid = uuid_dir.upper()
        sim_total += size_bytes
        info = device_info.get(uuid, {})
        name = info.get("name", "unknown (orphaned)")
        runtime = info.get("runtime", "")
        display = f"{name} ({runtime})" if runtime else name

        if uuid in unavailable or info == {}:
            status = "unavail"
            unavail_bytes += size_bytes
            unavail_count += 1
        else:
            status = "ok"
            avail_count += 1
        sim_rows.append((size_bytes, display, status, uuid))

    sim_rows.sort(key=lambda r: r[0], reverse=True)
    safe_total += unavail_bytes  # only the unavailable portion is "safe to delete now"

report["simulators"] = {
    "total": sim_total,
    "avail_count": avail_count,
    "unavail_count": unavail_count,
    "unavail_bytes": unavail_bytes,
    "items": [{"name": d, "bytes": s, "status": st, "uuid": u} for s, d, st, u in sim_rows]
}

# ──────────────────────────────────────────────
#  4. Simulator Runtimes  (review — queried via simctl, NOT filesystem)
#     Xcode 14+: DMG images managed by simdiskimaged daemon
#     Xcode 16+: CryptexDiskImage via MobileAsset
#     All at /Library/Developer/CoreSimulator/ (system-level, not ~/Library)
# ──────────────────────────────────────────────
rt_total = 0
runtimes_found = False
runtime_rows = []  # [(name, size_bytes, uuid, deletable, last_used, kind)]

try:
    rt_out = subprocess.check_output(
        ["xcrun", "simctl", "runtime", "list", "-v"], text=True, stderr=subprocess.DEVNULL
    )
    cur = {"name": "", "uuid": "", "size": 0, "deletable": "", "last_used": "", "kind": ""}

    def flush_runtime():
        if cur["name"] and cur["size"] > 0:
            runtime_rows.append((cur["name"], cur["size"], cur["uuid"],
                                 cur["deletable"], cur["last_used"], cur["kind"]))

    for line in rt_out.splitlines():
        # Runtime header: "iOS 18.4 (22E238) - E2E5F921-..."
        m = re.match(r"^(\w[\w\s]*?\d+\.\d+)\s+\([^)]+\)\s+-\s+([A-Fa-f0-9-]{36})", line)
        if m:
            flush_runtime()
            cur = {"name": m.group(1), "uuid": m.group(2), "size": 0,
                   "deletable": "", "last_used": "", "kind": ""}
            continue
        stripped = line.strip()
        if stripped.startswith("Size:"):
            size_str = stripped.split(":", 1)[1].strip()
            # Parse "8.2G", "500M", etc.
            sm = re.match(r"([\d.]+)\s*([GMKT]?)B?", size_str, re.IGNORECASE)
            if sm:
                val = float(sm.group(1))
                unit = sm.group(2).upper()
                if unit == "G":   cur["size"] = int(val * 1073741824)
                elif unit == "M": cur["size"] = int(val * 1048576)
                elif unit == "K": cur["size"] = int(val * 1024)
                elif unit == "T": cur["size"] = int(val * 1099511627776)
                else:             cur["size"] = int(val)
        elif stripped.startswith("Deletable:"):
            cur["deletable"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("Last Used At:"):
            ts = stripped.split(":", 1)[1].strip()
            # Show just date portion: "2026-05-06 09:17:37 +0000" → "2026-05-06"
            cur["last_used"] = ts.split(" ")[0] if ts else ""
        elif stripped.startswith("Image Kind:"):
            cur["kind"] = stripped.split(":", 1)[1].strip()

    flush_runtime()
except Exception:
    pass

if runtime_rows:
    runtimes_found = True
    rt_total = sum(s for _, s, *_ in runtime_rows)
    review_total += rt_total
    runtime_rows.sort(key=lambda r: r[1], reverse=True)

report["runtimes"] = [
    {"name": n, "size": s, "uuid": u, "deletable": d, "last_used": lu, "kind": k}
    for n, s, u, d, lu, k in runtime_rows
]

# ──────────────────────────────────────────────
#  5. Archives  (REVIEW — may need for dSYM symbolication)
# ──────────────────────────────────────────────
# Check if user has a custom archives location
archives_dir = os.path.join(xcode_dev, "Archives")
try:
    custom = subprocess.check_output(
        ["defaults", "read", "com.apple.dt.Xcode", "IDECustomDistributionArchivesLocation"],
        text=True, stderr=subprocess.DEVNULL
    ).strip()
    if custom and os.path.isdir(custom):
        archives_dir = custom
except Exception:
    pass

archives_found = False
ar_total = 0
entries = []

if os.path.isdir(archives_dir):
    for date_folder in os.listdir(archives_dir):
        date_path = os.path.join(archives_dir, date_folder)
        if not os.path.isdir(date_path):
            continue
        for sub_name, sub_size in du_children(date_path):
            ar_total += sub_size
            display = sub_name.replace(".xcarchive", "")
            entries.append((display, date_folder, sub_size))

    if entries:
        archives_found = True
        review_total += ar_total
        entries.sort(key=lambda e: e[2], reverse=True)

report["archives"] = {
    "total": ar_total,
    "items": [{"name": d, "date": df, "bytes": s} for d, df, s in entries]
}

# ──────────────────────────────────────────────
#  6. Xcode caches  (safe)
# ──────────────────────────────────────────────
xcode_cache_paths = [
    (os.path.join(caches_dir, "com.apple.dt.Xcode"),       "Xcode app cache"),
    (os.path.join(caches_dir, "org.swift.swiftpm"),        "SwiftPM cache (system)"),
    (os.path.expanduser("~/.swiftpm"),                     "SwiftPM cache (user)"),
    (os.path.expanduser("~/Library/Developer/Xcode/UserData/IB Support"), "Interface Builder cache"),
]

cache_rows = []
for path, label in xcode_cache_paths:
    if os.path.isdir(path):
        size = du_total(path)
        if size > 0:
            cache_rows.append((label, path, size))

caches_total = sum(s for _, _, s in cache_rows)
if cache_rows:
    safe_total += caches_total

report["caches"] = {
    "total": caches_total,
    "items": [{"name": l, "path": p.replace(os.path.expanduser("~"), "~"), "bytes": s}
              for l, p, s in sorted(cache_rows, key=lambda r: r[2], reverse=True)]
}

# ──────────────────────────────────────────────
#  BUILD ACTIONS FOR REPORT
# ──────────────────────────────────────────────
actions = []

if derived_total > 0:
    actions.append({
        "tier": "safe", "title": f"Delete DerivedData ({fmt(derived_total)})",
        "desc": "Xcode rebuilds on next project open.",
        "cmds": ["rm -rf ~/Library/Developer/Xcode/DerivedData/*"]
    })

if ds_found:
    ds_cmds = []
    for folder_name, _ in platforms:
        support_dir = os.path.join(xcode_dev, folder_name)
        if os.path.isdir(support_dir) and os.listdir(support_dir):
            ds_cmds.append(f'rm -rf {support_dir.replace(" ", chr(92) + " ")}/*')
    if ds_cmds:
        actions.append({
            "tier": "safe", "title": f"Delete DeviceSupport ({fmt(ds_total)})",
            "desc": "Re-downloads on next device connect.",
            "cmds": ds_cmds
        })

if unavail_count > 0:
    actions.append({
        "tier": "safe", "title": f"Delete unavailable simulators ({fmt(unavail_bytes)})",
        "desc": f"{unavail_count} orphaned/unavailable devices.",
        "cmds": ["xcrun simctl delete unavailable"]
    })

if cache_rows:
    c_cmds = [f'rm -rf {p.replace(" ", chr(92) + " ")}' for _, p, _ in cache_rows]
    actions.append({
        "tier": "safe", "title": f"Clear caches ({fmt(caches_total)})",
        "desc": "Regenerated on use.",
        "cmds": c_cmds
    })

if runtimes_found:
    actions.append({
        "tier": "review", "title": f"Remove unused runtimes ({fmt(rt_total)})",
        "desc": "Managed by simdiskimaged daemon.",
        "cmds": ["xcrun simctl runtime delete unusable", "xcrun simctl runtime delete <UUID>"],
        "warn": "Never delete runtime files directly."
    })

if archives_found:
    actions.append({
        "tier": "review", "title": f"Review archives ({fmt(ar_total)})",
        "desc": "Xcode \u2192 Window \u2192 Organizer \u2192 Archives",
        "cmds": [],
        "warn": "Keep latest per shipped version (dSYMs for crash symbolication)."
    })

if avail_count > 0:
    actions.append({
        "tier": "review", "title": "Erase simulator data (optional)",
        "desc": "Wipes app installs AND simulator preferences.",
        "cmds": ["xcrun simctl erase all", "xcrun simctl erase <UUID>"],
        "warn": "Affects ALL active simulators."
    })

report["actions"] = actions
report["safe_total"] = safe_total
report["review_total"] = review_total

# ──────────────────────────────────────────────
#  GENERATE HTML REPORT
# ──────────────────────────────────────────────
template_path = os.path.join(script_dir, "xcode_report_template.html")
result_dir = os.path.join(script_dir, "Result")
result_path = os.path.join(result_dir, "xcode_report.html")

if os.path.isfile(template_path):
    os.makedirs(result_dir, exist_ok=True)
    with open(template_path, "r") as f:
        html = f.read()
    html = html.replace("__XCODE_DATA_PLACEHOLDER__", json.dumps(report))
    with open(result_path, "w") as f:
        f.write(html)
    print(f"\n✅ Report ready — opening {result_path}")
    subprocess.Popen(["open", result_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
else:
    print(f"\n⚠️  Template not found: {template_path}")

PYEOF
