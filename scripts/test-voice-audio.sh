#!/usr/bin/env bash
# Audio format, tap and listening status tests. Buffers are built in memory: no microphone.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-voice-audio.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc \
    NotchBuddy/Sources/App/Voice/EnergyVAD.swift \
    NotchBuddy/Sources/App/Voice/SpotterGeneration.swift \
    NotchBuddy/Sources/App/Voice/VoiceAudio.swift \
    NotchBuddy/Sources/App/Voice/VoiceCommandCapture.swift \
    NotchBuddy/Sources/App/Voice/VoiceListenStatus.swift \
    NotchBuddy/Sources/App/Voice/VoiceLocalePlan.swift \
    NotchBuddy/Sources/App/Voice/WakePhrase.swift \
    tests/VoiceAudioTests.swift \
    -o "$TEST_DIR/voice-audio-tests"
"$TEST_DIR/voice-audio-tests"
