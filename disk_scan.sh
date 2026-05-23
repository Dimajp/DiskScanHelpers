#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  disk_scan.sh  —  Disk Usage Report Generator
#  Usage:  bash disk_scan.sh [directory] [depth]
#  Default: scans $HOME, depth 3
# ─────────────────────────────────────────────

TARGET="${1:-$HOME}"
DEPTH="${2:-3}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_HTML="$SCRIPT_DIR/disk_report_template.html"

echo "🔍 Scanning: $TARGET (depth $DEPTH) ..."
echo "   This may take a moment..."

# ── Helper: bytes → human readable
human() {
  local b=$1
  if   [ "$b" -ge 1073741824 ]; then printf "%.1f GB" "$(echo "$b 1073741824" | awk '{printf "%.1f", $1/$2}')";
  elif [ "$b" -ge 1048576 ];    then printf "%.1f MB" "$(echo "$b 1048576"    | awk '{printf "%.1f", $1/$2}')";
  elif [ "$b" -ge 1024 ];       then printf "%.1f KB" "$(echo "$b 1024"       | awk '{printf "%.1f", $1/$2}')";
  else printf "%d B" "$b"; fi
}

# ── Collect du data (512-byte blocks on macOS → multiply by 512)
# Exclude Time Machine / network mounts to keep it fast
TMP=$(mktemp)
du -d "$DEPTH" -x "$TARGET" 2>/dev/null | sort -rn > "$TMP"

TOTAL_BLOCKS=$(head -1 "$TMP" | awk '{print $1}')
TOTAL_BYTES=$(( TOTAL_BLOCKS * 512 ))

echo "   Total: $(human $TOTAL_BYTES)"

# ── Build data and inject into HTML template → Result/
RESULT_DIR="$SCRIPT_DIR/Result"
mkdir -p "$RESULT_DIR"
RESULT_HTML="$RESULT_DIR/disk_report.html"

python3 - <<PYEOF
import os, json

tmp_file  = "$TMP"
target    = "$TARGET"
depth_max = int("$DEPTH")

rows = []
with open(tmp_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        blocks, path = int(parts[0]), parts[1]
        size_bytes = blocks * 512
        rel = os.path.relpath(path, target)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        rows.append({
            "path": path,
            "rel":  rel if rel != "." else "/",
            "name": os.path.basename(path) if rel != "." else os.path.basename(target),
            "bytes": size_bytes,
            "depth": depth
        })

rows.sort(key=lambda r: r["bytes"], reverse=True)

def build_node(row, all_rows):
    path = row["path"]
    depth = row["depth"]
    children = [
        r for r in all_rows
        if r["depth"] == depth + 1 and r["path"].startswith(path + "/")
    ]
    children.sort(key=lambda r: r["bytes"], reverse=True)
    return {
        "name":  row["name"],
        "rel":   row["rel"],
        "bytes": row["bytes"],
        "children": [build_node(c, all_rows) for c in children[:50]]
    }

root_rows = [r for r in rows if r["depth"] == 0]
if not root_rows:
    root_rows = [rows[0]] if rows else []

root = build_node(root_rows[0], rows) if root_rows else {"name": target, "rel": "/", "bytes": 0, "children": []}
top = [r for r in rows if r["depth"] == 1][:100]

output = {
    "target": target,
    "total_bytes": root_rows[0]["bytes"] if root_rows else 0,
    "tree": root,
    "top": top
}

json_str = json.dumps(output)

html = open("$OUT_HTML").read()
html = html.replace("__DISK_DATA_PLACEHOLDER__", json_str)

with open("$RESULT_HTML", "w") as f:
    f.write(html)

print(f"   Report written: $RESULT_HTML")
PYEOF

rm "$TMP"

echo ""
echo "✅ Done! Opening report..."
open "$RESULT_HTML"
