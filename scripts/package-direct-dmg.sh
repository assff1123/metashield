#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_BUNDLE="$PROJECT_DIR/work/package.noindex/MetaShield.app"
STAGING_DIR="$PROJECT_DIR/work/direct-dmg-staging.noindex"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/packaging/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/packaging/Info.plist")
DMG_PATH="$OUTPUT_DIR/MetaShield-$VERSION-direct.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
TEMP_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/MetaShieldDirect.XXXXXX")
TEMP_DMG="$TEMP_DIR/MetaShield.dmg"

cleanup() {
    /bin/rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

swift run --package-path "$PROJECT_DIR" -c release metashield-self-test
"$PROJECT_DIR/scripts/build-app.sh"

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")
BUILT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")
if [[ "$VERSION" != "$BUILT_VERSION" || "$BUILD" != "$BUILT_BUILD" ]]; then
    echo "빌드된 앱의 버전이 패키징 설정과 일치하지 않습니다." >&2
    exit 1
fi

/bin/rm -rf "$STAGING_DIR"
/bin/mkdir -p "$STAGING_DIR"
/usr/bin/ditto "$APP_BUNDLE" "$STAGING_DIR/MetaShield.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"
/bin/cp "$PROJECT_DIR/packaging/직접 배포 설치 안내.txt" "$STAGING_DIR/처음 설치 방법.txt"
# Apache-2.0 requires that recipients of the work get a copy of the license.
/bin/cp "$PROJECT_DIR/LICENSE" "$STAGING_DIR/LICENSE.txt"

/usr/bin/hdiutil create \
    -volname "MetaShield $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDZO \
    "$TEMP_DMG"

# Ad-hoc signing preserves integrity but deliberately does not establish an
# Apple-verified developer identity. Gatekeeper rejection is expected.
/usr/bin/codesign --force --sign - "$TEMP_DMG"
/usr/bin/hdiutil verify "$TEMP_DMG"
/usr/bin/codesign --verify --verbose=2 "$TEMP_DMG"

/bin/mv -f "$TEMP_DMG" "$DMG_PATH"
(
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 "${DMG_PATH:t}"
) > "$CHECKSUM_PATH"

echo "$DMG_PATH"
echo "$CHECKSUM_PATH"
