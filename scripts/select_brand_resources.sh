#!/bin/sh
# Only this phase emits localized InfoPlist.strings and GoogleService-Info.plist.
# Validate every input before writing anything. Never select a fallback brand.
set -eu
fail() { echo "error: Brand resources: $1" >&2; exit 1; }
: "${SRCROOT:?}" "${CONFIGURATION:?}" "${APP_BRAND:?}" "${PRODUCT_BUNDLE_IDENTIFIER:?}"
: "${TARGET_BUILD_DIR:?}" "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
case "$CONFIGURATION:$APP_BRAND:$PRODUCT_BUNDLE_IDENTIFIER:${APP_URL_SCHEME:-}:${BRAND_RELEASE_AUDIT:-}" in
    Debug:woowtech:io.woowtech.odoo:woowodoo:NO|Release:woowtech:io.woowtech.odoo:woowodoo:YES|ApporoDebug:apporo:com.apporo.odoo.dev:apporoodoo-dev:NO|ApporoRelease:apporo:com.apporo.odoo:apporoodoo:YES) ;;
    *) fail "unknown or inconsistent variant" ;;
esac
[ -n "${FIREBASE_CONFIG_PATH:-}" ] && [ -f "$FIREBASE_CONFIG_PATH" ] || fail "selected Firebase plist is missing; provision this variant before building"
[ -n "${FIREBASE_EXPECTED_PROJECT_ID:-}" ] || fail "verified Firebase project ID is required"
/usr/bin/plutil -lint "$FIREBASE_CONFIG_PATH" >/dev/null 2>&1 || fail "invalid Firebase plist"
# Validate required client fields without emitting their values to build logs.
for key in GOOGLE_APP_ID GCM_SENDER_ID API_KEY; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$FIREBASE_CONFIG_PATH" 2>/dev/null) || fail "required Firebase client field missing"
    [ -n "$value" ] || fail "required Firebase client field empty"
done
unset value
bundle=$(/usr/libexec/PlistBuddy -c 'Print :BUNDLE_ID' "$FIREBASE_CONFIG_PATH" 2>/dev/null) || fail "Firebase bundle ID missing"
project=$(/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' "$FIREBASE_CONFIG_PATH" 2>/dev/null) || fail "Firebase project ID missing"
[ "$bundle" = "$PRODUCT_BUNDLE_IDENTIFIER" ] && [ "$project" = "$FIREBASE_EXPECTED_PROJECT_ID" ] || fail "Firebase identity mismatch"
# An Apporo input must not point at either existing WOOW or AIoT Firebase.
if [ "$APP_BRAND" = apporo ]; then
    case "$project" in woow*|*aiot*) fail "Apporo Odoo requires its own Firebase project" ;; esac
fi
for lang in en zh-Hans zh-Hant; do
    source="$SRCROOT/BrandResources/$APP_BRAND/$lang.lproj/InfoPlist.strings"
    [ -f "$source" ] || fail "localized brand resource missing"
    /usr/bin/plutil -lint "$source" >/dev/null 2>&1 || fail "invalid localized brand resource"
done
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$destination"
cp "$FIREBASE_CONFIG_PATH" "$destination/GoogleService-Info.plist"
for lang in en zh-Hans zh-Hant; do
    mkdir -p "$destination/$lang.lproj"
    cp "$SRCROOT/BrandResources/$APP_BRAND/$lang.lproj/InfoPlist.strings" "$destination/$lang.lproj/InfoPlist.strings"
done
