#!/usr/bin/env bash
# This fork's name ("Jarvis") and default language, and the string catalog that shows it.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-brand.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc \
    NotchBuddy/Sources/App/Brand.swift \
    tests/BrandTests.swift -o "$TEST_DIR/brand-tests"
"$TEST_DIR/brand-tests"
python3 scripts/jarvis-brand.py --check
