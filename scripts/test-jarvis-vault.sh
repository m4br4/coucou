#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-jarvis-vault.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    NotchBuddy/Sources/App/Jarvis/JarvisVault.swift \
    NotchBuddy/Sources/App/Jarvis/JarvisApprovals.swift \
    NotchBuddy/Sources/App/Voice/JarvisLink.swift \
    tests/JarvisVaultTests.swift -o "$TEST_DIR/jarvis-vault-tests"
"$TEST_DIR/jarvis-vault-tests"
