#!/usr/bin/env bash
# Builds this fork (Release) from a clean copy of the latest commit and leaves it in
# /Applications/Jarvis.app. Running it again with nothing new changes nothing.
#
# The checkout is only pulled: xcodegen and the build run in a clone, so uncommitted work
# (a regenerated project.pbxproj, the string catalog) stays as it is and is not built.
#
# Signed without the author's Team or profiles: with an Apple Development certificate of
# another Team when the Mac has one, else ad-hoc. Without a profile there is no iCloud, so
# the build uses the entitlements without it and leaves the iPhone link (PHONE_LINK) out.
# macOS sees an ad-hoc app as a new app after each build and asks its permissions again;
# JARVIS_SIGN_IDENTITY avoids it with any certificate that stays the same.
#
#   ./scripts/instalar-jarvis-app.sh
#
#   JARVIS_SIGN_IDENTITY  sign with this identity
#   JARVIS_APP_DIR        install there instead of /Applications (running apps stay open)
#   JARVIS_BUILD_DIR      clone and build there instead of ~/Library/Caches/JarvisApp
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="fr.louisraille.NotchBuddy"
AUTHOR_TEAM="256AUJ9555"
APP_DIR="${JARVIS_APP_DIR:-/Applications}"
QUIT_RUNNING="${JARVIS_QUIT_RUNNING:-$([ -n "${JARVIS_APP_DIR:-}" ] && echo 0 || echo 1)}"
BUILD_DIR="${JARVIS_BUILD_DIR:-${HOME}/Library/Caches/JarvisApp}"
TARGET="${APP_DIR}/Jarvis.app"
STAGE="${APP_DIR}/.Jarvis.app.new"
SOURCE="${BUILD_DIR}/source"
DERIVED="${BUILD_DIR}/DerivedData"
BUILT="${DERIVED}/Build/Products/Release/Coucou.app"
LOG="${BUILD_DIR}/build.log"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

die() { echo "✗ $*" >&2; exit 1; }

plist_value() {
  [ -f "$1/Contents/Info.plist" ] || return 0
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true
}

# The App Store Coucou runs under the same process name: only this bundle id counts.
running_pids() {
  local pid exe
  for pid in $(pgrep -x Coucou 2>/dev/null || true); do
    exe=$(ps -o comm= -p "$pid" 2>/dev/null || true)
    if [ "$(plist_value "${exe%/Contents/MacOS/*}" CFBundleIdentifier)" = "${BUNDLE_ID}" ]; then
      echo "$pid"
    fi
  done
}

wait_until_quit() {
  for _ in 1 2 3 4 5; do
    [ -n "$(running_pids)" ] || return 0
    sleep 1
  done
  return 1
}

quit_running() {
  [ -n "$(running_pids)" ] || return 0
  echo "Quitting the running app..."
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  wait_until_quit && return 0
  kill $(running_pids) 2>/dev/null || true
  wait_until_quit || die "The running app did not quit. Nothing was replaced."
}

# Prints "identity<TAB>team" for the first Apple Development certificate of another Team.
local_identity() {
  local name team
  while IFS= read -r name; do
    team=$(security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
      | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' || true)
    if [ -n "$team" ] && [ "$team" != "${AUTHOR_TEAM}" ]; then
      printf '%s\t%s\n' "$name" "$team"
      return 0
    fi
  done < <(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)".*/\1/p' || true)
}

summary() {
  echo "✓ $1"
  echo "  App:     ${TARGET} ($(plist_value "${TARGET}" CFBundleShortVersionString))"
  echo "  Commit:  ${HASH}"
  echo "  In app:  $(plist_value "${TARGET}" CoucouGitHash)"
  echo "  Signed:  $(codesign -dvv "${TARGET}" 2>&1 | sed -n 's/^Authority=//p' | head -1 | grep . || echo ad-hoc)"
}

xcodebuild -version >/dev/null 2>&1 \
  || die "Xcode not found (xcode-select points to $(xcode-select -p 2>/dev/null || echo nothing)). Is its volume mounted? Nothing was built."
command -v xcodegen >/dev/null || die "xcodegen not found: brew install xcodegen. Nothing was built."

echo "Pulling..."
if ! PULL=$(git -C "${REPO_ROOT}" pull --ff-only 2>&1); then
  echo "${PULL}" >&2
  die "git pull --ff-only failed: nothing was built or installed. The checkout was left as it was."
fi
HASH=$(git -C "${REPO_ROOT}" rev-parse HEAD)
DIRTY=$(git -C "${REPO_ROOT}" status --porcelain | wc -l | tr -d ' ')
[ "${DIRTY}" = "0" ] || echo "${DIRTY} uncommitted change(s) in the checkout: left alone and not built."

if [ -e "${TARGET}" ]; then
  EXISTING=$(plist_value "${TARGET}" CFBundleIdentifier)
  [ "${EXISTING}" = "${BUNDLE_ID}" ] || die "${TARGET} is another app (${EXISTING:-no bundle id}): not touching it."
  INSTALLED=$(plist_value "${TARGET}" CoucouGitHash)
  if [ -n "${INSTALLED}" ] && [ "${HASH:0:${#INSTALLED}}" = "${INSTALLED}" ] \
    && codesign --verify --deep --strict "${TARGET}" >/dev/null 2>&1; then
    summary "Already installed, nothing to do."
    exit 0
  fi
fi

IDENTITY="-"
TEAM=""
if [ -n "${JARVIS_SIGN_IDENTITY:-}" ]; then
  IDENTITY="${JARVIS_SIGN_IDENTITY}"
else
  LOCAL=$(local_identity)
  if [ -n "${LOCAL}" ]; then
    IDENTITY="${LOCAL%%$'\t'*}"
    TEAM="${LOCAL##*$'\t'}"
  fi
fi

echo "Building ${HASH} (Release, signed with: ${IDENTITY})..."
mkdir -p "${BUILD_DIR}"
rm -rf "${SOURCE}" "${BUILT}"
git clone -q --no-checkout "${REPO_ROOT}" "${SOURCE}"
git -C "${SOURCE}" checkout -q --detach "${HASH}"
cd "${SOURCE}/NotchBuddy"
xcodegen >"${LOG}" 2>&1 || { tail -20 "${LOG}" >&2; die "xcodegen failed. Nothing was installed."; }
# In a clean build the "Write Git Hash" phase can run before Xcode copies Info.plist, which
# then wipes the hash: it goes in the source too. Only this clone's copy changes.
SHORT_HASH=$(git -C "${SOURCE}" rev-parse --short HEAD)
/usr/libexec/PlistBuddy -c "Set :CoucouGitHash ${SHORT_HASH}" Resources/Info.plist 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CoucouGitHash string ${SHORT_HASH}" Resources/Info.plist >/dev/null
# These settings reach every target, FluidAudio's too: the entitlements path must be absolute.
# SYMROOT and OBJROOT because a custom build location in Xcode's preferences beats -derivedDataPath.
xcodebuild -project NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Release \
  -derivedDataPath "${DERIVED}" SYMROOT="${DERIVED}/Build/Products" \
  OBJROOT="${DERIVED}/Build/Intermediates.noindex" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${IDENTITY}" DEVELOPMENT_TEAM="${TEAM}" \
  PROVISIONING_PROFILE_SPECIFIER= OTHER_CODE_SIGN_FLAGS= \
  CODE_SIGN_ENTITLEMENTS="${SOURCE}/NotchBuddy/Resources/Coucou.entitlements" SWIFT_ACTIVE_COMPILATION_CONDITIONS= \
  build >>"${LOG}" 2>&1 || { grep -E "error:" "${LOG}" | head -20 >&2 || true; die "Build failed (${LOG}). Nothing was installed."; }

BUILT_HASH=$(plist_value "${BUILT}" CoucouGitHash)
[ -n "${BUILT_HASH}" ] && [ "${HASH:0:${#BUILT_HASH}}" = "${BUILT_HASH}" ] \
  || die "The build says it is ${BUILT_HASH:-no commit}, not ${HASH}. Nothing was installed."
codesign --verify --deep --strict "${BUILT}" >/dev/null 2>&1 || die "The build's signature is not valid. Nothing was installed."

trap 'rm -rf "${STAGE}"' EXIT
rm -rf "${STAGE}"
ditto "${BUILT}" "${STAGE}" || die "Cannot write in ${APP_DIR}. Nothing was installed."
[ "${QUIT_RUNNING}" = "0" ] || quit_running
rm -rf "${TARGET}"
mv "${STAGE}" "${TARGET}"

# The build stays in the cache, but macOS must not count it as another copy of the app.
"${LSREGISTER}" -u "${BUILT}" >/dev/null 2>&1 || true

summary "Installed."
for other in /Applications/Coucou.app "${HOME}/Applications/Coucou.app"; do
  if [ "$(plist_value "${other}" CFBundleIdentifier)" = "${BUNDLE_ID}" ]; then
    echo "  Note: ${other} has the same bundle id: run only one of them."
  fi
done
