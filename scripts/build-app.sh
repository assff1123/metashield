#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
OUTPUT_DIR="$PROJECT_DIR/outputs"
DEVELOPER_OUTPUT_DIR="$OUTPUT_DIR/developer"
WORK_DIR="$PROJECT_DIR/work/package.noindex"
APP_TEMP="$WORK_DIR/MetaShield.app"

HOST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/packaging/Info.plist")
SHARE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/packaging/share/Info.plist")
WORKFLOW_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/packaging/quick-action/MetaShield 메타데이터 완전 제거.workflow/Contents/Info.plist")
HOST_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/packaging/Info.plist")
SHARE_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/packaging/share/Info.plist")
WORKFLOW_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/packaging/quick-action/MetaShield 메타데이터 완전 제거.workflow/Contents/Info.plist")

if [[ "$HOST_VERSION:$HOST_BUILD" != "$SHARE_VERSION:$SHARE_BUILD" ]] || \
   [[ "$HOST_VERSION:$HOST_BUILD" != "$WORKFLOW_VERSION:$WORKFLOW_BUILD" ]]; then
    echo "앱·공유 확장·빠른 동작의 버전 또는 빌드 번호가 일치하지 않습니다." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR" "$DEVELOPER_OUTPUT_DIR" "$WORK_DIR"
rm -rf "$APP_TEMP"
mkdir -p "$APP_TEMP/Contents/MacOS" "$APP_TEMP/Contents/Resources" \
    "$APP_TEMP/Contents/PlugIns/MetaShield Share.appex/Contents/MacOS"

build_product() {
    local arch=$1
    local triple="${arch}-apple-macosx13.0"
    local build_dir="$WORK_DIR/build-$arch"
    swift build \
        --package-path "$PROJECT_DIR" \
        --build-path "$build_dir" \
        --triple "$triple" \
        -c release \
        -Xswiftc -warnings-as-errors \
        --product MetaShield
    swift build \
        --package-path "$PROJECT_DIR" \
        --build-path "$build_dir" \
        --triple "$triple" \
        -c release \
        -Xswiftc -warnings-as-errors \
        --product metashield-cli
    swift build \
        --package-path "$PROJECT_DIR" \
        --build-path "$build_dir" \
        --triple "$triple" \
        -c release \
        -Xswiftc -warnings-as-errors \
        --product MetaShieldShare
}

build_product arm64
build_product x86_64

/usr/bin/lipo -create \
    "$WORK_DIR/build-arm64/arm64-apple-macosx/release/MetaShield" \
    "$WORK_DIR/build-x86_64/x86_64-apple-macosx/release/MetaShield" \
    -output "$APP_TEMP/Contents/MacOS/MetaShield"

/usr/bin/lipo -create \
    "$WORK_DIR/build-arm64/arm64-apple-macosx/release/metashield-cli" \
    "$WORK_DIR/build-x86_64/x86_64-apple-macosx/release/metashield-cli" \
    -output "$APP_TEMP/Contents/Resources/metashield-cli"

/usr/bin/lipo -create \
    "$WORK_DIR/build-arm64/arm64-apple-macosx/release/MetaShieldShare" \
    "$WORK_DIR/build-x86_64/x86_64-apple-macosx/release/MetaShieldShare" \
    -output "$APP_TEMP/Contents/PlugIns/MetaShield Share.appex/Contents/MacOS/MetaShieldShare"

# SwiftPM records the build machine's toolchain in LC_RPATH. No load command
# uses @rpath, so the entry is dead weight that also leaks a local layout.
strip_toolchain_rpath() {
    local binary=$1
    local path
    /usr/bin/otool -l "$binary" | /usr/bin/awk '/LC_RPATH/ { rpath = 1; next } rpath && /path / { print $2; rpath = 0 }' | while read -r path; do
        case "$path" in
            *xctoolchain*) /usr/bin/install_name_tool -delete_rpath "$path" "$binary" 2>/dev/null || true ;;
        esac
    done
}

strip_toolchain_rpath "$APP_TEMP/Contents/MacOS/MetaShield"
strip_toolchain_rpath "$APP_TEMP/Contents/Resources/metashield-cli"
strip_toolchain_rpath "$APP_TEMP/Contents/PlugIns/MetaShield Share.appex/Contents/MacOS/MetaShieldShare"

/bin/cp "$PROJECT_DIR/packaging/Info.plist" "$APP_TEMP/Contents/Info.plist"
/bin/cp "$PROJECT_DIR/packaging/share/Info.plist" \
    "$APP_TEMP/Contents/PlugIns/MetaShield Share.appex/Contents/Info.plist"
/usr/bin/ditto \
    "$PROJECT_DIR/packaging/quick-action/MetaShield 메타데이터 완전 제거.workflow" \
    "$APP_TEMP/Contents/Resources/MetaShieldQuickAction.workflow"
/usr/bin/swift "$PROJECT_DIR/scripts/make-icon.swift" "$APP_TEMP/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$APP_TEMP/Contents/Info.plist"
/usr/bin/plutil -lint "$APP_TEMP/Contents/PlugIns/MetaShield Share.appex/Contents/Info.plist"
/usr/bin/plutil -lint "$APP_TEMP/Contents/Resources/MetaShieldQuickAction.workflow/Contents/Info.plist"

# Sign from the innermost code outward. Public releases must be re-signed and
# notarized with scripts/sign-and-notarize.sh.
/usr/bin/codesign --force --options runtime --sign - \
    "$APP_TEMP/Contents/Resources/metashield-cli"
/usr/bin/codesign --force --options runtime \
    --entitlements "$PROJECT_DIR/packaging/MetaShieldShare.entitlements" \
    --sign - "$APP_TEMP/Contents/PlugIns/MetaShield Share.appex"
/usr/bin/codesign --force --options runtime \
    --entitlements "$PROJECT_DIR/packaging/MetaShield.entitlements" \
    --sign - "$APP_TEMP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_TEMP"

LOCAL_ZIP="$DEVELOPER_OUTPUT_DIR/MetaShield-$HOST_VERSION-local.zip"
rm -f "$LOCAL_ZIP" "$LOCAL_ZIP.sha256"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_TEMP" "$LOCAL_ZIP"
/usr/bin/shasum -a 256 "$LOCAL_ZIP" > "$LOCAL_ZIP.sha256"

echo "$APP_TEMP"
echo "$LOCAL_ZIP"
echo "$LOCAL_ZIP.sha256"
