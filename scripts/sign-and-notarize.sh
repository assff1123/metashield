#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_BUNDLE="$PROJECT_DIR/work/package.noindex/MetaShield.app"
OUTPUT_DIR="$PROJECT_DIR/outputs"
DMG_STAGING="$PROJECT_DIR/work/dmg-staging.noindex"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/packaging/Info.plist")
SIGNED_DMG="$OUTPUT_DIR/MetaShield-$VERSION.dmg"
CHECKSUM_FILE="$SIGNED_DMG.sha256"
NOTARY_RESULT="$OUTPUT_DIR/MetaShield-$VERSION.notary-result.plist"
NOTARY_LOG="$OUTPUT_DIR/MetaShield-$VERSION.notary-log.json"

: "${METASHIELD_SIGN_IDENTITY:?Set METASHIELD_SIGN_IDENTITY to a Developer ID Application identity}"
: "${METASHIELD_NOTARY_PROFILE:?Set METASHIELD_NOTARY_PROFILE to a notarytool keychain profile}"

if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    echo "전체 Xcode를 설치하고 xcode-select가 Xcode.app을 가리키게 하세요." >&2
    exit 1
fi
CODE_SIGNING_IDENTITIES=$(/usr/bin/security find-identity -v -p codesigning)
if [[ "$CODE_SIGNING_IDENTITIES" != *"\"$METASHIELD_SIGN_IDENTITY\""* ]]; then
    echo "키체인에서 지정한 Developer ID Application 서명 ID를 찾지 못했습니다." >&2
    exit 1
fi
if ! /usr/bin/xcrun --find notarytool >/dev/null 2>&1; then
    echo "현재 Xcode에서 notarytool을 찾지 못했습니다." >&2
    exit 1
fi

HOST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/packaging/Info.plist")
SHARE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/packaging/share/Info.plist")
WORKFLOW_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/packaging/quick-action/MetaShield 메타데이터 완전 제거.workflow/Contents/Info.plist")
HOST_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/packaging/Info.plist")
SHARE_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/packaging/share/Info.plist")
WORKFLOW_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/packaging/quick-action/MetaShield 메타데이터 완전 제거.workflow/Contents/Info.plist")
HOST_RELEASE="$HOST_VERSION:$HOST_BUILD"
SHARE_RELEASE="$SHARE_VERSION:$SHARE_BUILD"
WORKFLOW_RELEASE="$WORKFLOW_VERSION:$WORKFLOW_BUILD"
if [[ "$HOST_RELEASE" != "$SHARE_RELEASE" ]]; then
    echo "호스트·공유 확장·빠른 동작의 버전 또는 빌드 번호가 일치하지 않습니다." >&2
    exit 1
fi
if [[ "$HOST_RELEASE" != "$WORKFLOW_RELEASE" ]]; then
    echo "호스트·공유 확장·빠른 동작의 버전 또는 빌드 번호가 일치하지 않습니다." >&2
    exit 1
fi

"$PROJECT_DIR/scripts/build-app.sh"

/usr/bin/codesign \
    --force \
    --strict \
    --timestamp \
    --options runtime \
    --sign "$METASHIELD_SIGN_IDENTITY" \
    "$APP_BUNDLE/Contents/Resources/metashield-cli"

/usr/bin/codesign \
    --force \
    --strict \
    --timestamp \
    --options runtime \
    --entitlements "$PROJECT_DIR/packaging/MetaShieldShare.entitlements" \
    --sign "$METASHIELD_SIGN_IDENTITY" \
    "$APP_BUNDLE/Contents/PlugIns/MetaShield Share.appex"

/usr/bin/codesign \
    --force \
    --strict \
    --timestamp \
    --options runtime \
    --entitlements "$PROJECT_DIR/packaging/MetaShield.entitlements" \
    --sign "$METASHIELD_SIGN_IDENTITY" \
    "$APP_BUNDLE"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
/usr/bin/ditto "$APP_BUNDLE" "$DMG_STAGING/MetaShield.app"
/bin/ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$SIGNED_DMG" "$CHECKSUM_FILE" "$NOTARY_RESULT" "$NOTARY_LOG"
/usr/bin/hdiutil create \
    -volname "MetaShield $VERSION" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$SIGNED_DMG"

/usr/bin/codesign \
    --force \
    --timestamp \
    --identifier "kr.metashield.app.dmg" \
    --sign "$METASHIELD_SIGN_IDENTITY" \
    "$SIGNED_DMG"
/usr/bin/codesign --verify --strict --verbose=2 "$SIGNED_DMG"
/usr/bin/hdiutil verify "$SIGNED_DMG"
/usr/bin/xcrun notarytool submit "$SIGNED_DMG" \
    --keychain-profile "$METASHIELD_NOTARY_PROFILE" \
    --wait \
    --output-format plist > "$NOTARY_RESULT"

NOTARY_ID=$(/usr/libexec/PlistBuddy -c 'Print :id' "$NOTARY_RESULT")
NOTARY_STATUS=$(/usr/libexec/PlistBuddy -c 'Print :status' "$NOTARY_RESULT")
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "공증이 승인되지 않았습니다: $NOTARY_STATUS ($NOTARY_ID)" >&2
    exit 1
fi

/usr/bin/xcrun notarytool log "$NOTARY_ID" \
    --keychain-profile "$METASHIELD_NOTARY_PROFILE" \
    "$NOTARY_LOG"

if /usr/bin/grep -Eq '"severity"[[:space:]]*:' "$NOTARY_LOG"; then
    echo "공증 로그에 warning 또는 error가 있습니다: $NOTARY_LOG" >&2
    exit 1
fi

/usr/bin/xcrun stapler staple "$SIGNED_DMG"
/usr/bin/xcrun stapler validate "$SIGNED_DMG"
/usr/sbin/spctl --assess --type open \
    --context context:primary-signature \
    --verbose=2 "$SIGNED_DMG"
/usr/bin/shasum -a 256 "$SIGNED_DMG" > "$CHECKSUM_FILE"

echo "$SIGNED_DMG"
echo "$CHECKSUM_FILE"
echo "$NOTARY_RESULT"
echo "$NOTARY_LOG"
