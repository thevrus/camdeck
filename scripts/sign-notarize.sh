#!/bin/bash
# Developer ID signing and notarization. Both steps skip with a log line when their secrets are absent,
# so the unsigned (ad-hoc) release flow keeps working.
#
# Usage:
#   scripts/sign-notarize.sh app [build/Camdeck.app]   re-sign the app inside-out with hardened runtime
#   scripts/sign-notarize.sh dmg [build/Camdeck.dmg]   sign the dmg, notarize it, staple it
#
# Env:
#   SIGN_IDENTITY   e.g. "Developer ID Application: Name (TEAMID)". Empty = skip signing and notarizing.
#   NOTARY_KEY_ID, NOTARY_ISSUER, NOTARY_KEY_P8   App Store Connect API key (P8 file contents). Any empty = skip notarizing.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:?usage: sign-notarize.sh app|dmg [path]}"
ENTITLEMENTS=scripts/Camdeck.entitlements

skip() { echo "sign-notarize: skipping, $1"; exit 0; }

sign_app() {
    local app="${1:-build/Camdeck.app}"
    [ -n "${SIGN_IDENTITY:-}" ] || skip "SIGN_IDENTITY not set; leaving $app ad-hoc signed (unsigned release)"
    [ -d "$app" ] || { echo "no app at $app" >&2; exit 1; }
    local fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    local flags=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")

    echo "sign-notarize: signing $app as '$SIGN_IDENTITY'"
    # Inside-out, never --deep (Sparkle docs). Each helper first, then the framework, then the app.
    # Sparkle 2.6+: Downloader.xpc keeps the entitlements it ships with.
    codesign "${flags[@]}" "$fw/XPCServices/Installer.xpc"
    codesign "${flags[@]}" --preserve-metadata=entitlements "$fw/XPCServices/Downloader.xpc"
    codesign "${flags[@]}" "$fw/Autoupdate"
    codesign "${flags[@]}" "$fw/Updater.app"
    codesign "${flags[@]}" "$app/Contents/Frameworks/Sparkle.framework"
    codesign "${flags[@]}" --entitlements "$ENTITLEMENTS" "$app"

    codesign --verify --strict --verbose=2 "$app"
    codesign -dvv --entitlements - "$app" 2>&1 | grep -E 'Authority|TeamIdentifier|flags|device\.' || true
}

notarize_dmg() {
    local dmg="${1:-build/Camdeck.dmg}"
    [ -n "${SIGN_IDENTITY:-}" ] || skip "SIGN_IDENTITY not set; $dmg stays unsigned and not notarized"
    [ -f "$dmg" ] || { echo "no dmg at $dmg" >&2; exit 1; }
    echo "sign-notarize: signing $dmg"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
    if [ -z "${NOTARY_KEY_ID:-}" ] || [ -z "${NOTARY_ISSUER:-}" ] || [ -z "${NOTARY_KEY_P8:-}" ]; then
        skip "NOTARY_KEY_ID, NOTARY_ISSUER or NOTARY_KEY_P8 missing; $dmg is signed but not notarized"
    fi

    # Global on purpose: the EXIT trap runs after this function has returned.
    KEYDIR="$(mktemp -d)"
    trap 'rm -rf "$KEYDIR"' EXIT
    local key="$KEYDIR/AuthKey_${NOTARY_KEY_ID}.p8"
    printf '%s\n' "$NOTARY_KEY_P8" > "$key"

    echo "sign-notarize: submitting $dmg to Apple notary service (waits for the verdict)"
    local out status id
    out="$(xcrun notarytool submit "$dmg" --key "$key" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait --output-format json)"
    echo "$out"
    status="$(printf '%s' "$out" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)"
    id="$(printf '%s' "$out" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)"
    if [ "$status" != "Accepted" ]; then
        echo "sign-notarize: notarization status '$status'; fetching log" >&2
        [ -z "$id" ] || xcrun notarytool log "$id" --key "$key" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" >&2 || true
        exit 1
    fi

    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    echo "sign-notarize: notarized and stapled $dmg"
}

case "$MODE" in
    app) sign_app "${2:-}" ;;
    dmg) notarize_dmg "${2:-}" ;;
    *) echo "usage: sign-notarize.sh app|dmg [path]" >&2; exit 2 ;;
esac
