#!/usr/bin/env bash
# The real JarvisApprovalStore, with real FSEvents and the real socket, without a screen.
# AppState and Touch ID are fakes; HOME and the vault are temporary folders.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-jarvis-store.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    NotchBuddy/Sources/App/Jarvis/JarvisApprovals.swift \
    NotchBuddy/Sources/App/Jarvis/JarvisApprovalSocket.swift \
    NotchBuddy/Sources/App/Jarvis/JarvisApprovalsPanel.swift \
    NotchBuddy/Sources/App/Jarvis/JarvisRequest.swift \
    tests/JarvisStoreTests.swift -o "$TEST_DIR/jarvis-store-tests"
# sun_path is short: TMPDIR may not fit.
HOME_DIR="$(mktemp -d /tmp/jv-store.XXXXXX 2>/dev/null || mktemp -d "$TEST_DIR/h.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$HOME_DIR"' EXIT
mkdir -p "$HOME_DIR/Library/Application Support"
HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" "$TEST_DIR/jarvis-store-tests"
