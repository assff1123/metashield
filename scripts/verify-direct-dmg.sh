#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
DMG_PATH=${1:-}

if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
    echo "사용법: $0 /path/to/MetaShield-x.y.z-direct.dmg" >&2
    exit 64
fi

MOUNT_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/MetaShieldDirectMount.XXXXXX")
COPY_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/MetaShieldDirectGatekeeper.XXXXXX")
mounted=false

cleanup() {
    if [[ "$mounted" == true ]]; then
        /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    /bin/rm -rf "$MOUNT_DIR" "$COPY_DIR"
}
trap cleanup EXIT

/usr/bin/hdiutil verify "$DMG_PATH"
/usr/bin/codesign --verify --verbose=2 "$DMG_PATH"
CHECKSUM_PATH="$DMG_PATH.sha256"
if [[ -f "$CHECKSUM_PATH" ]]; then
    expected=$(/usr/bin/awk 'NR == 1 { print $1 }' "$CHECKSUM_PATH")
    actual=$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{ print $1 }')
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
        echo "DMG의 SHA-256 체크섬이 일치하지 않습니다." >&2
        exit 1
    fi
fi
/usr/bin/hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_DIR" -quiet
mounted=true

APP_PATH="$MOUNT_DIR/MetaShield.app"
if [[ ! -d "$APP_PATH" || ! -f "$MOUNT_DIR/처음 설치 방법.txt" || \
      ! -f "$MOUNT_DIR/LICENSE.txt" ]]; then
    echo "DMG에 앱, 설치 안내 또는 라이선스 사본이 없습니다." >&2
    exit 1
fi
if ! /usr/bin/cmp -s "$PROJECT_DIR/LICENSE" "$MOUNT_DIR/LICENSE.txt"; then
    echo "DMG의 LICENSE.txt가 저장소 라이선스와 일치하지 않습니다." >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

require_universal() {
    local executable=$1
    local architectures
    architectures=$(/usr/bin/lipo -archs "$executable")
    if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
        echo "Universal 2 바이너리가 아닙니다: $executable ($architectures)" >&2
        exit 1
    fi
}

require_universal "$APP_PATH/Contents/MacOS/MetaShield"
require_universal "$APP_PATH/Contents/MacOS/metashield-cli"
require_universal "$APP_PATH/Contents/XPCServices/MetaShieldDecodeService.xpc/Contents/MacOS/MetaShieldDecodeService"
require_universal "$APP_PATH/Contents/PlugIns/MetaShield Share.appex/Contents/MacOS/MetaShieldShare"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -lint "$APP_PATH/Contents/PlugIns/MetaShield Share.appex/Contents/Info.plist"
DECODE_PATH="$APP_PATH/Contents/XPCServices/MetaShieldDecodeService.xpc"
/usr/bin/plutil -lint "$DECODE_PATH/Contents/Info.plist"

# The decoder is a security boundary, so its packaging is checked rather than
# assumed: exactly one entitlement, and a version that matches the host.
DECODE_ENTITLEMENTS=$(/usr/bin/codesign -d --entitlements - --xml "$DECODE_PATH" 2>/dev/null \
    | /usr/bin/plutil -convert json -o - - \
    | /usr/bin/python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin).keys())))')
if [[ "$DECODE_ENTITLEMENTS" != "com.apple.security.app-sandbox" ]]; then
    echo "디코드 서비스의 entitlement가 app-sandbox 하나가 아닙니다: $DECODE_ENTITLEMENTS" >&2
    exit 1
fi
echo "디코드 서비스 entitlement 확인: $DECODE_ENTITLEMENTS"

HOST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
SHARE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/PlugIns/MetaShield Share.appex/Contents/Info.plist")
HOST_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
SHARE_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/PlugIns/MetaShield Share.appex/Contents/Info.plist")
DECODE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DECODE_PATH/Contents/Info.plist")
DECODE_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DECODE_PATH/Contents/Info.plist")
if [[ "$HOST_VERSION:$HOST_BUILD" != "$SHARE_VERSION:$SHARE_BUILD" ]]; then
    echo "DMG 안의 앱·공유 확장 버전이 일치하지 않습니다." >&2
    exit 1
fi
if [[ "$HOST_VERSION:$HOST_BUILD" != "$DECODE_VERSION:$DECODE_BUILD" ]]; then
    echo "DMG 안의 앱·디코드 서비스 버전이 일치하지 않습니다." >&2
    exit 1
fi

/usr/bin/ditto "$APP_PATH" "$COPY_DIR/MetaShield.app"
/usr/bin/xattr -w com.apple.quarantine "0081;$(/bin/date +%s);MetaShieldDirectAudit;" "$COPY_DIR/MetaShield.app"
if /usr/sbin/spctl --assess --type execute --verbose=2 "$COPY_DIR/MetaShield.app"; then
    echo "예상과 달리 Developer ID 없이 Gatekeeper 평가를 통과했습니다." >&2
    exit 1
else
    echo "예상된 Gatekeeper 차단 확인: 최초 실행 때 '확인 없이 열기'가 필요합니다."
fi

# The isolated decoder must be reachable from the shipped bundle and must
# produce exactly what the in-process path produces. A release where the
# service is missing or mismatched would silently lose its isolation.
SAMPLE="$COPY_DIR/xpc-sample.png"
/usr/bin/sips -s format png -Z 256 \
    "/System/Library/Desktop Pictures/Solid Colors/Stone.png" --out "$SAMPLE" >/dev/null 2>&1
if [[ -f "$SAMPLE" ]]; then
    "$APP_PATH/Contents/MacOS/metashield-cli" --xpc-self-test "$SAMPLE"
else
    echo "격리 디코더 검사를 위한 표본 이미지를 만들지 못했습니다." >&2
    exit 1
fi

swift run --package-path "$PROJECT_DIR" -c release metashield-self-test
echo "직접 배포 DMG 무결성·서명 구조·Universal 2·격리 디코더·예상 Gatekeeper 동작·자체 테스트 통과"
