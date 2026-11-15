#!/bin/sh
# Compile the v5 sheet renderer with the app's Core sources and run it on this repository.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/sheet-v5-renderer"
swiftc -O -module-name SheetV5 "$ROOT"/frontend/IPadApp/IPadApp/Core/*.swift "$ROOT/scripts/sheet-v5/main.swift" -o "$OUT"
"$OUT" "$ROOT"
