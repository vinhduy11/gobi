#!/bin/sh
# Runs the Swift tests. The Command Line Tools ship Swift Testing outside SwiftPM's default search path,
# so point the compiler and linker at it. With full Xcode installed plain `swift test` works too.
set -eu
cd "$(dirname "$0")/.."
./scripts/check-layers.sh
FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$FRAMEWORKS/Testing.framework" ] && ! xcode-select -p | grep -q Xcode; then
    exec swift test -Xswiftc -F"$FRAMEWORKS" -Xlinker -F"$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
fi
exec swift test "$@"
