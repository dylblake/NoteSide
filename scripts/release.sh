#!/usr/bin/env bash
#
# scripts/release.sh — build, sign, notarize, staple, and package NoteSide
# for distribution outside the Mac App Store.
#
# Prerequisites (one-time):
#   1. Developer ID Application certificate installed in the login keychain.
#      Verify with: security find-identity -v -p codesigning
#   2. Notarization credentials stored under the keychain profile
#      "noteside-notary". Set up with:
#        xcrun notarytool store-credentials "noteside-notary" \
#          --apple-id <APPLE_ID> --team-id 57SW9PT7P8 --password <APP_SPECIFIC_PWD>
#
# Outputs (under build/):
#   build/NoteSide.xcarchive   — full archive (debug symbols etc.)
#   build/export/NoteSide.app  — exported, signed, stapled .app
#   build/NoteSide.zip         — zip submitted to notarytool
#   build/NoteSide.dmg         — distributable disk image (signed + notarized)
#
# Usage:
#   ./scripts/release.sh

set -euo pipefail

# Resolve repo root regardless of where the script is invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="NoteSide.xcodeproj"
SCHEME="NoteSide"
CONFIGURATION="Release"
TEAM_ID="57SW9PT7P8"
SIGN_IDENTITY="Developer ID Application: Dylan Evans (${TEAM_ID})"
KEYCHAIN_PROFILE="noteside-notary"
EXPORT_OPTIONS="exportOptions.plist"

BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/NoteSide.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
APP_PATH="${EXPORT_DIR}/NoteSide.app"
ZIP_PATH="${BUILD_DIR}/NoteSide.zip"
DMG_PATH="${BUILD_DIR}/NoteSide.dmg"
DMG_STAGING="${BUILD_DIR}/dmg-staging"

# Color helpers
if [[ -t 1 ]]; then
    BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
    GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; RED="$(tput setaf 1)"
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""
fi

step() { echo; echo "${BOLD}${GREEN}==>${RESET}${BOLD} $*${RESET}"; }
info() { echo "${DIM}    $*${RESET}"; }
warn() { echo "${YELLOW}    $*${RESET}"; }
fail() { echo "${RED}    $*${RESET}" >&2; exit 1; }

# Pre-flight checks
step "Pre-flight checks"

if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    fail "Signing identity not found in keychain: $SIGN_IDENTITY"
fi
info "Signing identity present."

if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    fail "Keychain profile '$KEYCHAIN_PROFILE' not configured for notarytool. See header comment."
fi
info "Notarization credentials present."

if [[ ! -f "$EXPORT_OPTIONS" ]]; then
    fail "Missing $EXPORT_OPTIONS at repo root."
fi
info "Export options found."

# Clean previous artifacts
step "Cleaning previous build artifacts"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
info "Cleared $BUILD_DIR/"

# Archive
step "Archiving Release build"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    | xcbeautify 2>/dev/null || \
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    > "$BUILD_DIR/archive.log" 2>&1 || { tail -50 "$BUILD_DIR/archive.log"; fail "xcodebuild archive failed. Full log: $BUILD_DIR/archive.log"; }

[[ -d "$ARCHIVE_PATH" ]] || fail "Archive missing at $ARCHIVE_PATH"
info "Archive: $ARCHIVE_PATH"

# Export
step "Exporting signed .app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    > "$BUILD_DIR/export.log" 2>&1 || { tail -50 "$BUILD_DIR/export.log"; fail "Export failed. Full log: $BUILD_DIR/export.log"; }

[[ -d "$APP_PATH" ]] || fail "Exported .app missing at $APP_PATH"
info ".app: $APP_PATH"

# Verify entitlements + signature before notarization
step "Verifying signature and entitlements"
codesign --verify --strict --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/    /'

if codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null | grep -q "get-task-allow"; then
    warn "get-task-allow is present — notarization will reject this build."
    warn "Re-check that the Release config does not enable debugging."
    fail "Aborting before notarization."
fi
info "Hardened runtime + entitlements look clean."

# Zip for notarization
step "Zipping for notarytool"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
info "Zip: $ZIP_PATH ($(du -h "$ZIP_PATH" | awk '{print $1}'))"

# Submit + wait
step "Submitting to Apple notarization service"
info "This typically takes 1–5 minutes..."
SUBMIT_OUTPUT="$BUILD_DIR/notarize.log"
if ! xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait \
    > "$SUBMIT_OUTPUT" 2>&1; then
    cat "$SUBMIT_OUTPUT"
    SUBMISSION_ID="$(grep -oE 'id: [a-f0-9-]+' "$SUBMIT_OUTPUT" | head -1 | awk '{print $2}')"
    if [[ -n "$SUBMISSION_ID" ]]; then
        echo
        warn "Fetching detailed log for submission $SUBMISSION_ID..."
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$KEYCHAIN_PROFILE" || true
    fi
    fail "Notarization failed."
fi
cat "$SUBMIT_OUTPUT" | sed 's/^/    /'

if ! grep -q "status: Accepted" "$SUBMIT_OUTPUT"; then
    SUBMISSION_ID="$(grep -oE 'id: [a-f0-9-]+' "$SUBMIT_OUTPUT" | head -1 | awk '{print $2}')"
    if [[ -n "$SUBMISSION_ID" ]]; then
        warn "Fetching log for non-accepted submission $SUBMISSION_ID..."
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$KEYCHAIN_PROFILE" || true
    fi
    fail "Notarization did not return Accepted."
fi

# Staple
step "Stapling notarization ticket onto the .app"
xcrun stapler staple "$APP_PATH" 2>&1 | sed 's/^/    /'

# Final verification — Gatekeeper assessment
step "Gatekeeper verification"
spctl -a -vv -t install "$APP_PATH" 2>&1 | sed 's/^/    /' || warn "spctl returned non-zero (may still be acceptable for first-run)."

# Build a DMG for distribution
step "Building distributable DMG"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "NoteSide" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" \
    > "$BUILD_DIR/dmg.log" 2>&1 || { tail -30 "$BUILD_DIR/dmg.log"; fail "DMG creation failed."; }

rm -rf "$DMG_STAGING"
info "DMG: $DMG_PATH ($(du -h "$DMG_PATH" | awk '{print $1}'))"

# Sign the DMG itself
step "Signing the DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH" 2>&1 | sed 's/^/    /'

# Notarize the DMG so users don't see "downloaded from internet" warnings
step "Notarizing the DMG"
if ! xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait \
    > "$BUILD_DIR/notarize-dmg.log" 2>&1; then
    cat "$BUILD_DIR/notarize-dmg.log"
    fail "DMG notarization failed."
fi
cat "$BUILD_DIR/notarize-dmg.log" | sed 's/^/    /'

step "Stapling ticket onto the DMG"
xcrun stapler staple "$DMG_PATH" 2>&1 | sed 's/^/    /'

step "${GREEN}Done.${RESET}"
echo
echo "    ${BOLD}Distributable artifact:${RESET} $DMG_PATH"
echo "    ${BOLD}Signed app:${RESET}             $APP_PATH"
echo
echo "    Verify on a test machine with:"
echo "      ${DIM}spctl -a -vv -t install $APP_PATH${RESET}"
echo "      ${DIM}xcrun stapler validate $DMG_PATH${RESET}"
