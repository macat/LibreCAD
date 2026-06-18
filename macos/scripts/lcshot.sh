#!/usr/bin/env bash
#
# lcshot.sh — build-once-then-run wrapper for the LCShot GUI screenshot harness.
#
# LCShot drives a HEADLESS CanvasModel from a JSON action script and renders the
# drawing's COMMITTED geometry to a PNG via the panel-free / device-free export
# path (no Metal, no window, no NSApplication, no save/open panel). Use it to
# eyeball how a feature behaved without launching the GUI.
#
# USAGE
#   macos/scripts/lcshot.sh <sceneName> [out.png]
#   macos/scripts/lcshot.sh --demo [out.png]
#   macos/scripts/lcshot.sh --list
#
#   <sceneName>  A scene under macos/engine/Harness/scripts/ WITHOUT the .json
#                extension (e.g. `line`, `mirror`, `hatch`, `dimension`,
#                `perpendicular`, `parameter`, `layout-switch`). The PNG is written
#                to macos/build/harness-shots/<sceneName>.png (a gitignored dir).
#                A full path to a .json file also works.
#
# Run from anywhere — the script cd's to the repo root (so the in-repo font /
# .pat hatch-pattern asset dirs resolve) and writes PNGs under macos/build/.
#
# COVERAGE CEILING (be honest): the PNG shows COMMITTED geometry only, framed
# fit-to-page, on the CAD canvas background. It does NOT show the grid, selection
# highlight, snap marker, in-flight tool preview, crosshair, grips/gizmo, the
# constraint glyph, the live-dimension chip, or any SwiftUI chrome (menus / sheets
# / sidebar / layout tabs / Preferences).
#
# GPLv2-or-later (LibreCAD derivative).
# Copyright (C) 2026 LibreCAD macOS contributors.

set -euo pipefail

# Resolve the repo root from this script's location (macos/scripts/lcshot.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

PKG="macos/engine"
SCENES_DIR="macos/engine/Harness/scripts"
OUT_DIR="macos/build/harness-shots"

usage() {
    sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

if [[ $# -lt 1 ]]; then
    usage
    exit 2
fi

case "$1" in
    -h|--help)
        usage
        exit 0
        ;;
    --list)
        echo "Available scenes (macos/engine/Harness/scripts/):"
        for f in "$SCENES_DIR"/*.json; do
            [[ -e "$f" ]] || continue
            echo "  $(basename "${f%.json}")"
        done
        exit 0
        ;;
esac

mkdir -p "$OUT_DIR"

# Build LCShot once (so repeated scene runs don't each pay a full build).
echo "lcshot: building LCShot…" >&2
swift build --package-path "$PKG" --disable-sandbox --product LCShot >&2

if [[ "$1" == "--demo" ]]; then
    OUT="${2:-$OUT_DIR/demo.png}"
    swift run --package-path "$PKG" --disable-sandbox LCShot --demo "$OUT"
    echo "lcshot: wrote $OUT"
    exit 0
fi

NAME="$1"
# Accept either a bare scene name or a path to a .json file.
if [[ -f "$NAME" ]]; then
    SCENE="$NAME"
    BASE="$(basename "${NAME%.json}")"
else
    SCENE="$SCENES_DIR/$NAME.json"
    BASE="$NAME"
fi

if [[ ! -f "$SCENE" ]]; then
    echo "lcshot: no such scene '$NAME' (looked for $SCENE)" >&2
    echo "lcshot: run 'macos/scripts/lcshot.sh --list' to see available scenes." >&2
    exit 1
fi

OUT="${2:-$OUT_DIR/$BASE.png}"

echo "lcshot: running scene '$BASE' -> $OUT" >&2
swift run --package-path "$PKG" --disable-sandbox LCShot "$SCENE" "$OUT"
echo "lcshot: done. Open $OUT to inspect the result."
