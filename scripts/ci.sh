#!/bin/sh
# What CI runs: Go vet and race tests for the core, then the Swift tests, the layer check and a build of the app, and the tests of the release scripts.
set -eu
cd "$(dirname "$0")/.."
(cd core && go vet ./... && go test -race ./...)
(cd ui/macos && ./scripts/check-layers.sh && ./scripts/test.sh && swift build)
python3 -m unittest discover -s scripts/tests
