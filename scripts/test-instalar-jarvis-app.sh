#!/usr/bin/env bash
# Runs scripts/instalar-jarvis-app.sh against a throwaway repo, with Xcode and the
# commands that reach the Mac (codesign, security, osascript, pgrep, ps) stubbed:
# nothing is written in /Applications and no running app is closed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/instalar-jarvis.XXXXXX")"
SLEEPER=""
trap '[ -z "$SLEEPER" ] || kill "$SLEEPER" 2>/dev/null || true; rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ ! -f "$T/out" ] || sed 's/^/    /' "$T/out"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

mkdir -p "$T/stubs" "$T/apps"
cat > "$T/stubs/xcodebuild" <<'STUB'
#!/bin/bash
[ "$1" != "-version" ] || { [ ! -f "$STUBS_STATE/no-xcode" ] && echo "Xcode 27.1"; exit $?; }
echo "$*" >> "$STUBS_STATE/xcodebuild.args"
[ ! -f "$STUBS_STATE/build-fails" ] || { echo "x.swift:1: error: boom"; exit 65; }
[ ! -f "$STUBS_STATE/no-product" ] || exit 0
while [ $# -gt 0 ]; do [ "$1" != "-derivedDataPath" ] || derived="$2"; shift; done
app="$derived/Build/Products/Release/Coucou.app/Contents"
mkdir -p "$app"
hash=$(cat "$STUBS_STATE/built-hash" 2>/dev/null || /usr/libexec/PlistBuddy -c "Print :CoucouGitHash" Resources/Info.plist)
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string fr.louisraille.NotchBuddy" \
  -c "Add :CFBundleShortVersionString string 0.0.1" -c "Add :CoucouGitHash string $hash" "$app/Info.plist" >/dev/null
cp ../marker.txt "$app/marker.txt"
STUB
cat > "$T/stubs/xcodegen" <<'STUB'
#!/bin/bash
echo generated >> project.pbxproj.generated
rm -f Resources/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Jarvis" Resources/Info.plist >/dev/null
STUB
cat > "$T/stubs/codesign" <<'STUB'
#!/bin/bash
[ "$1" != "-dvv" ] || { echo "Authority=stub" >&2; exit 0; }
[ ! -f "$STUBS_STATE/bad-signature" ]
STUB
cat > "$T/stubs/security" <<'STUB'
#!/bin/bash
[ "$1" != "find-identity" ] || cat "$STUBS_STATE/identities" 2>/dev/null || true
STUB
cat > "$T/stubs/osascript" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUBS_STATE/osascript.args"
[ ! -f "$STUBS_STATE/quit-pid" ] || kill "$(cat "$STUBS_STATE/quit-pid")"
STUB
cat > "$T/stubs/pgrep" <<'STUB'
#!/bin/bash
for f in "$STUBS_STATE"/pid-*; do
  [ -e "$f" ] || continue
  pid=${f##*/pid-}
  kill -0 "$pid" 2>/dev/null && echo "$pid"
done
true
STUB
cat > "$T/stubs/ps" <<'STUB'
#!/bin/bash
cat "$STUBS_STATE/pid-${@: -1}"
STUB
chmod +x "$T"/stubs/*

export STUBS_STATE="$T/state"
mkdir -p "$STUBS_STATE"
git init -q --bare "$T/origin.git"
git init -q -b main "$T/repo"
git_id=(-c user.name=Test -c user.email=test@example.invalid)
PBXPROJ="$T/repo/NotchBuddy/NotchBuddy.xcodeproj/project.pbxproj"
mkdir -p "$T/repo/scripts" "$T/repo/NotchBuddy/Resources" "$T/repo/NotchBuddy/NotchBuddy.xcodeproj"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Jarvis" "$T/repo/NotchBuddy/Resources/Info.plist" >/dev/null
cp "$ROOT/scripts/instalar-jarvis-app.sh" "$T/repo/scripts/"
echo one > "$T/repo/marker.txt"
echo tracked > "$PBXPROJ"
git -C "$T/repo" add -A
git -C "$T/repo" "${git_id[@]}" commit -qm first
git -C "$T/repo" remote add origin "$T/origin.git"
git -C "$T/repo" push -q -u origin main
git clone -q "$T/origin.git" "$T/other"

run() {
  JARVIS_APP_DIR="$T/apps" JARVIS_BUILD_DIR="$T/build" JARVIS_QUIT_RUNNING="${QUIT:-0}" PATH="$T/stubs:$PATH" \
    "$T/repo/scripts/instalar-jarvis-app.sh" > "$T/out" 2>&1
}
push_from_other() {
  echo "$2" > "$T/other/$1"
  git -C "$T/other" add -A
  git -C "$T/other" "${git_id[@]}" commit -qm "$2"
  git -C "$T/other" pull -q --rebase origin main
  git -C "$T/other" push -q origin HEAD:main
}
builds() { wc -l < "$STUBS_STATE/xcodebuild.args" | tr -d ' '; }
installed() { cat "$T/apps/Jarvis.app/Contents/marker.txt"; }
out_has() { grep -qF -- "$1" "$T/out"; }

# No Xcode: says so and stops.
touch "$STUBS_STATE/no-xcode"
check "no Xcode fails" '! run'
check "no Xcode is explained" 'out_has "Xcode not found"'
check "no Xcode installs nothing" '[ ! -e "$T/apps/Jarvis.app" ]'
rm "$STUBS_STATE/no-xcode"

# First install: from the commit, without the author's signing or iCloud.
check "first install works" 'run'
HASH=$(git -C "$T/repo" rev-parse HEAD)
check "app installed as Jarvis.app" '[ "$(installed)" = one ]'
check "summary shows the full hash" 'out_has "$HASH"'
check "summary shows the hash in the app" 'out_has "In app:  ${HASH:0:7}"'
ARGS=$(cat "$STUBS_STATE/xcodebuild.args")
check "Release" '[[ "$ARGS" == *"-configuration Release"* ]]'
check "products stay in the build folder" '[[ "$ARGS" == *"SYMROOT=$T/build/DerivedData/Build/Products "* ]]'
check "ad-hoc without a certificate" '[[ "$ARGS" == *"CODE_SIGN_IDENTITY=- "* ]]'
check "not the author's Team" '[[ "$ARGS" == *"DEVELOPMENT_TEAM= "* && "$ARGS" != *256AUJ9555* ]]'
check "no profile" '[[ "$ARGS" == *"PROVISIONING_PROFILE_SPECIFIER= "* ]]'
check "entitlements without iCloud" '[[ "$ARGS" == *"CODE_SIGN_ENTITLEMENTS=$T/build/source/NotchBuddy/Resources/Coucou.entitlements"* ]]'
check "no iPhone link" '[[ "$ARGS" == *"SWIFT_ACTIVE_COMPILATION_CONDITIONS= "* ]]'
check "xcodegen ran in the clone" '[ -f "$T/build/source/NotchBuddy/project.pbxproj.generated" ]'
check "xcodegen did not run in the checkout" '[ ! -e "$T/repo/NotchBuddy/project.pbxproj.generated" ]'
check "checkout stays clean" '[ -z "$(git -C "$T/repo" status --porcelain)" ]'
check "no staging copy left" '[ ! -e "$T/apps/.Jarvis.app.new" ]'

# Idempotent: same commit, no build.
check "second run works" 'run'
check "second run does not build" '[ "$(builds)" = 1 ]'
check "second run says so" 'out_has "Already installed"'

# A new commit is pulled, built and replaces the app.
push_from_other marker.txt two
check "update works" 'run'
check "update replaced the app" '[ "$(installed)" = two ]'
check "update built once more" '[ "$(builds)" = 2 ]'

# Only project.pbxproj modified: put back, then pulled and installed.
echo regenerated > "$PBXPROJ"
push_from_other marker.txt three
check "only pbxproj modified installs" 'run'
check "pbxproj put back" '[ "$(cat "$PBXPROJ")" = tracked ]'
check "pbxproj put back is reported" 'out_has "Putting back"'
check "pbxproj install has the new commit" '[ "$(installed)" = three ]'
check "checkout clean after putting pbxproj back" '[ -z "$(git -C "$T/repo" status --porcelain)" ]'

# Untracked files do not count and stay.
mkdir -p "$T/repo/NotchBuddy/NotchBuddy.xcodeproj/project.xcworkspace/xcshareddata"
echo mine > "$T/repo/NotchBuddy/NotchBuddy.xcodeproj/project.xcworkspace/xcshareddata/x"
push_from_other marker.txt three-b
check "untracked file does not stop it" 'run'
check "untracked file stays" '[ "$(cat "$T/repo/NotchBuddy/NotchBuddy.xcodeproj/project.xcworkspace/xcshareddata/x")" = mine ]'
check "untracked file is not built" '[ ! -e "$T/build/source/NotchBuddy/NotchBuddy.xcodeproj/project.xcworkspace/xcshareddata" ]'
rm -rf "$T/repo/NotchBuddy/NotchBuddy.xcodeproj/project.xcworkspace"

# Any other modified file, alone or with project.pbxproj: stops, touches nothing.
push_from_other marker.txt three-c
HEAD_BEFORE=$(git -C "$T/repo" rev-parse HEAD)
BUILDS_BEFORE=$(builds)
APP_BEFORE=$(installed)
echo mine > "$T/repo/marker.txt"
check "other modified file fails" '! run'
check "other modified file is named" 'out_has "marker.txt"'
check "other modified file is explained" 'out_has "Nothing was touched"'
check "other modified file kept" '[ "$(cat "$T/repo/marker.txt")" = mine ]'
echo regenerated > "$PBXPROJ"
check "pbxproj plus another file fails" '! run'
check "pbxproj kept when another file is modified" '[ "$(cat "$PBXPROJ")" = regenerated ]'
check "other file kept with pbxproj" '[ "$(cat "$T/repo/marker.txt")" = mine ]'
check "no pull with modified files" '[ "$(git -C "$T/repo" rev-parse HEAD)" = "$HEAD_BEFORE" ]'
check "no build with modified files" '[ "$(builds)" = "$BUILDS_BEFORE" ]'
check "app stays with modified files" '[ "$(installed)" = "$APP_BEFORE" ]'
git -C "$T/repo" checkout -q -- marker.txt NotchBuddy/NotchBuddy.xcodeproj/project.pbxproj
check "clean checkout pulls again" 'run'

# No Xcode: a modified project.pbxproj is not put back either.
echo regenerated > "$PBXPROJ"
touch "$STUBS_STATE/no-xcode"
check "no Xcode fails with pbxproj modified" '! run'
check "no Xcode keeps pbxproj" '[ "$(cat "$PBXPROJ")" = regenerated ]'
rm "$STUBS_STATE/no-xcode"
git -C "$T/repo" checkout -q -- NotchBuddy/NotchBuddy.xcodeproj/project.pbxproj

# A pull that cannot fast-forward (an untracked file in its way): stops, keeps everything.
echo mine > "$T/repo/incoming.txt"
push_from_other incoming.txt theirs
HEAD_BEFORE=$(git -C "$T/repo" rev-parse HEAD)
BUILDS_BEFORE=$(builds)
check "blocked pull fails" '! run'
check "failed pull is explained" 'out_has "git pull --ff-only failed"'
check "file survives a failed pull" '[ "$(cat "$T/repo/incoming.txt")" = mine ]'
check "head stays after a failed pull" '[ "$(git -C "$T/repo" rev-parse HEAD)" = "$HEAD_BEFORE" ]'
check "nothing built after a failed pull" '[ "$(builds)" = "$BUILDS_BEFORE" ]'
rm "$T/repo/incoming.txt"

# Diverged history: same.
echo local > "$T/repo/local.txt"
git -C "$T/repo" add -A
git -C "$T/repo" "${git_id[@]}" commit -qm local
check "diverged pull fails" '! run'
check "diverged pull is explained" 'out_has "git pull --ff-only failed"'
git -C "$T/repo" reset -q --hard HEAD~1
git -C "$T/repo" pull -q --ff-only

# A failed build leaves the installed app and any running one alone.
touch "$STUBS_STATE/build-fails"
sleep 60 & SLEEPER=$!
echo "$T/apps/Jarvis.app/Contents/MacOS/Coucou" > "$STUBS_STATE/pid-$SLEEPER"
BEFORE=$(installed)
check "failed build fails" '! QUIT=1 run'
check "failed build shows the error" 'out_has "error: boom"'
check "failed build keeps the app" '[ "$(installed)" = "$BEFORE" ]'
check "failed build keeps the running app" 'kill -0 "$SLEEPER"'
rm "$STUBS_STATE/build-fails"

# A build that leaves no app, of another commit or with a bad signature is not installed.
touch "$STUBS_STATE/no-product"
check "no product fails" '! run'
check "no product is explained" 'out_has "The build says it is no commit"'
rm "$STUBS_STATE/no-product"
echo 0000000 > "$STUBS_STATE/built-hash"
check "wrong hash fails" '! run'
check "wrong hash is explained" 'out_has "The build says it is 0000000"'
rm "$STUBS_STATE/built-hash"
touch "$STUBS_STATE/bad-signature"
check "bad signature fails" '! run'
check "bad signature keeps the app" '[ "$(installed)" = "$BEFORE" ]'
rm "$STUBS_STATE/bad-signature"

# The running app is closed only after the build, and only this bundle id.
mkdir -p "$T/store/Coucou.app/Contents"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string fr.louisraille.Coucou" "$T/store/Coucou.app/Contents/Info.plist" >/dev/null
sleep 60 & STORE=$!
echo "$T/store/Coucou.app/Contents/MacOS/Coucou" > "$STUBS_STATE/pid-$STORE"
echo "$SLEEPER" > "$STUBS_STATE/quit-pid"
push_from_other marker.txt four
check "install with a running app works" 'QUIT=1 run'
check "running app asked to quit" 'grep -q "fr.louisraille.NotchBuddy" "$STUBS_STATE/osascript.args"'
check "running app closed" '! kill -0 "$SLEEPER" 2>/dev/null'
check "App Store Coucou left open" 'kill -0 "$STORE"'
kill "$STORE"
rm "$STUBS_STATE"/pid-* "$STUBS_STATE/quit-pid"
SLEEPER=""

# With JARVIS_APP_DIR no running app is closed.
sleep 60 & SLEEPER=$!
echo "$T/apps/Jarvis.app/Contents/MacOS/Coucou" > "$STUBS_STATE/pid-$SLEEPER"
push_from_other marker.txt five
JARVIS_APP_DIR="$T/apps" JARVIS_BUILD_DIR="$T/build" PATH="$T/stubs:$PATH" "$T/repo/scripts/instalar-jarvis-app.sh" > "$T/out" 2>&1
check "JARVIS_APP_DIR leaves running apps open" 'kill -0 "$SLEEPER"'
kill "$SLEEPER"
rm "$STUBS_STATE"/pid-*
SLEEPER=""

# "IT Crowd Local" signs when the Mac has it; other certificates do not count.
printf '  1) AAA "Apple Development: Author (X)"\n' > "$STUBS_STATE/identities"
push_from_other marker.txt six
run
check "ad-hoc without the local identity" '[[ "$(tail -1 "$STUBS_STATE/xcodebuild.args")" == *"CODE_SIGN_IDENTITY=- "* ]]'
printf '  1) AAA "Apple Development: Author (X)"\n  2) BBB "IT Crowd Local"\n     2 valid identities found\n' > "$STUBS_STATE/identities"
push_from_other marker.txt seven
run
LAST=$(tail -1 "$STUBS_STATE/xcodebuild.args")
check "local identity used" '[[ "$LAST" == *"CODE_SIGN_IDENTITY=IT Crowd Local "* ]]'
check "no Team with the local identity" '[[ "$LAST" == *"DEVELOPMENT_TEAM= "* ]]'
push_from_other marker.txt eight
JARVIS_SIGN_IDENTITY="Some Other" run
check "JARVIS_SIGN_IDENTITY wins" '[[ "$(tail -1 "$STUBS_STATE/xcodebuild.args")" == *"CODE_SIGN_IDENTITY=Some Other "* ]]'

# Something else at the target is never replaced.
rm -rf "$T/apps/Jarvis.app"
mkdir -p "$T/apps/Jarvis.app/Contents"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.other" "$T/apps/Jarvis.app/Contents/Info.plist" >/dev/null
check "another app at the target fails" '! run'
check "another app is explained" 'out_has "is another app (com.example.other)"'
check "another app stays" '[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$T/apps/Jarvis.app/Contents/Info.plist")" = com.example.other ]'

echo "$PASS/$((PASS + FAIL)) tests passed."
[ "$FAIL" = 0 ]
