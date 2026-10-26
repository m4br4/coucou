#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-jarvis-link.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    NotchBuddy/Sources/App/Voice/JarvisLink.swift \
    tests/JarvisLinkTests.swift -o "$TEST_DIR/jarvis-link-tests"
"$TEST_DIR/jarvis-link-tests"
