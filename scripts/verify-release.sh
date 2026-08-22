#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
DMG_PATH=${1:-}

if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
    echo "사용법: $0 /path/to/MetaShield-x.y.z.dmg" >&2
    exit 64
fi

MOUNT_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/MetaShieldMount.XXXXXX")
COPY_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/MetaShieldGatekeeper.XXXXXX")
mounted=false

cleanup() {
    if [[ "$mounted" == true ]]; then
        /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    /bin/rm -rf "$MOUNT_DIR" "$COPY_DIR"
}
trap cleanup EXIT

/usr/bin/xcrun stapler validate "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"
/usr/sbin/spctl --assess --type open \
    --context context:primary-signature \
    --verbose=2 "$DMG_PATH"
/usr/bin/hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_DIR" -quiet
mounted=true

APP_PATH="$MOUNT_DIR/MetaShield.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "DMG에 MetaShield.app이 없습니다." >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP_PATH"

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
require_universal "$APP_PATH/Contents/Resources/metashield-cli"
require_universal "$APP_PATH/Contents/PlugIns/MetaShield Share.appex/Contents/MacOS/MetaShieldShare"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -lint "$APP_PATH/Contents/PlugIns/MetaShield Share.appex/Contents/Info.plist"

/usr/bin/ditto "$APP_PATH" "$COPY_DIR/MetaShield.app"
/usr/bin/xattr -w com.apple.quarantine "0081;$(/bin/date +%s);MetaShieldReleaseAudit;" "$COPY_DIR/MetaShield.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$COPY_DIR/MetaShield.app"

swift run --package-path "$PROJECT_DIR" metashield-self-test
echo "공증·Gatekeeper·서명·Universal·자체 테스트 통과"
