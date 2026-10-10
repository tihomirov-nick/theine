#!/bin/bash
# Renders the app icon, Resources/AppIcon.icon and Resources/AppIcon-1024.png. make_icon.swift draws the mark with the
# glyph files of the app (Sources/Theine/Glyph.swift and Theine.swift), so the two are compiled together; swiftc wants the
# file with the top-level code to be called main.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/scripts/make_icon.swift" "$WORK/main.swift"
swiftc -O "$WORK/main.swift" "$ROOT/Sources/Theine/Glyph.swift" "$ROOT/Sources/Theine/Theine.swift" -o "$WORK/make_icon"
ICON_ROOT="$ROOT" "$WORK/make_icon"
