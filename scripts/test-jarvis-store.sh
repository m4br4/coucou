#!/usr/bin/env bash
# The real JarvisApprovalStore, with real FSEvents and the real socket, without a screen.
# AppState and Touch ID are fakes; HOME and the vault are temporary folders.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-jarvis-store.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=(
    NotchBuddy/Sources/App/Jarvis/JarvisApprovals.swift
    NotchBuddy/Sources/App/Jarvis/JarvisApprovalSocket.swift
    NotchBuddy/Sources/App/Jarvis/JarvisApprovalsPanel.swift
    NotchBuddy/Sources/App/Jarvis/JarvisRequest.swift
    tests/JarvisStoreTests.swift
)
# Touch ID can only be replaced with this flag, which no app build sets.
if grep -q JARVIS_STORE_TESTS NotchBuddy/project.yml scripts/instalar-jarvis-app.sh scripts/dev-install.sh; then
    echo "JARVIS_STORE_TESTS reached an app build"; exit 1
fi
if swiftc -parse-as-library -typecheck "${SOURCES[@]}" 2> "$TEST_DIR/no-flag.log"; then
    echo "without the flag the test must not compile: confirmOwner would exist in the app"; exit 1
fi
grep -q "has no member 'confirmOwner'" "$TEST_DIR/no-flag.log"
echo "✓  without the flag there is no confirmOwner"
swiftc -parse-as-library -D JARVIS_STORE_TESTS "${SOURCES[@]}" -o "$TEST_DIR/jarvis-store-tests"
# sun_path is short: TMPDIR may not fit.
HOME_DIR="$(mktemp -d /tmp/jv-store.XXXXXX 2>/dev/null || mktemp -d "$TEST_DIR/h.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$HOME_DIR"' EXIT
mkdir -p "$HOME_DIR/Library/Application Support"
HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" "$TEST_DIR/jarvis-store-tests"
