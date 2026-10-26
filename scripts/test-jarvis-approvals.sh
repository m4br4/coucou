#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-jarvis-approvals.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    NotchBuddy/Sources/App/Jarvis/JarvisApprovals.swift \
    tests/JarvisApprovalsTests.swift -o "$TEST_DIR/jarvis-approvals-tests"
"$TEST_DIR/jarvis-approvals-tests"
