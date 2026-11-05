#!/bin/sh
# Fails when a Swift layer imports something its layer must not (see docs/architect/layers.md).
#   GobiModel   imports nothing
#   GobiClient  may import Foundation, Darwin, GobiModel; never AppKit, GobiEditor, GobiApp
#   GobiEditor  may import AppKit, Foundation, GobiModel, GobiClient; never GobiApp
set -eu
cd "$(dirname "$0")/.."
status=0
fail() { echo "layer violation: $1"; status=1; }

if rg -n '^\s*(@testable\s+)?import\s' Sources/GobiModel >/dev/null 2>&1; then
    fail "GobiModel must not import anything: $(rg -n '^\s*import\s' Sources/GobiModel | head -3)"
fi
if rg -n '^\s*import\s+(AppKit|Cocoa|SwiftUI|GobiEditor|GobiApp)\b' Sources/GobiClient >/dev/null 2>&1; then
    fail "GobiClient must not import a UI layer: $(rg -n '^\s*import\s+(AppKit|Cocoa|SwiftUI|GobiEditor|GobiApp)\b' Sources/GobiClient | head -3)"
fi
if rg -n '^\s*import\s+GobiApp\b' Sources/GobiEditor >/dev/null 2>&1; then
    fail "GobiEditor must not import GobiApp"
fi
[ "$status" -eq 0 ] && echo "layers ok"
exit "$status"
