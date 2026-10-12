#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
umask 077

# Reject missing consent and unknown options before build, runtime checks or launch.
if (( $# < 1 || $# > 2 )) || [[ "$1" != --build-only && "$1" != --allow-real-mail ]] ||
   { (( $# == 2 )) && [[ "$1" != --allow-real-mail || "$2" != --allow-cloud-generation && "$2" != --index-only ]]; }; then
  print -u2 'Use --build-only or --allow-real-mail [--allow-cloud-generation | --index-only].'
  exit 64
fi
MODE="$1"
CLOUD_FLAG="${2:-}"
RUNTIME_APP="${HARBOR_LIVE_RUNTIME_APP:-$PWD/dist/HarborReply-0.1.20/HarborReply.app}"
if [[ ! -x "$RUNTIME_APP/Contents/Resources/python-arm64/bin/python3" || ! -f "$RUNTIME_APP/Contents/Resources/runtime.lock.json" ]]; then
  print -u2 'The specified app has no packaged Apple Silicon Python runtime.'
  exit 1
fi
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp/}harborreply-simple-style.XXXXXX")"
chmod 700 "$WORK_DIR"
APP="$WORK_DIR/HarborReplySimpleStyle.app"
KEEP_BUILD=0
RECOVERY_PID=""
cleanup() { if (( KEEP_BUILD == 0 )); then rm -rf "$WORK_DIR"; fi }
trap cleanup EXIT
stop_recovery() {
  local task_exit="$1"
  trap - INT TERM
  if [[ -n "$RECOVERY_PID" ]]; then
    kill -TERM "$RECOVERY_PID" 2>/dev/null || true
    wait "$RECOVERY_PID" 2>/dev/null || true
  fi
  exit "$task_exit"
}
trap 'stop_recovery 130' INT
trap 'stop_recovery 143' TERM
if ! /usr/bin/swift build > "$WORK_DIR/build.log" 2>&1; then
  print -u2 'The host Swift build failed. No Mail recovery was started.'
  exit 1
fi
BIN_DIR="$(/usr/bin/swift build --show-bin-path 2>> "$WORK_DIR/build.log")"
ACCESSOR="$(rg --files .build -g resource_bundle_accessor.swift | rg '/Debug/HarborReply[^/]*/DerivedSources/' | head -1)"
if [[ -z "$ACCESSOR" || ! -f "$BIN_DIR/HarborCore.o" || ! -d "$BIN_DIR/HarborReply_HarborReply.bundle" ]]; then
  print -u2 'Style recovery requires the host SwiftPM/Xcode debug object layout.'
  exit 1
fi
typeset -a SOURCE_FILES
while IFS= read -r source; do
  if [[ "${source:t}" != App.swift && "${source:t}" != AppUpdater.swift ]]; then SOURCE_FILES+=("$source"); fi
done < <(rg --files Sources/HarborReply -g '*.swift')
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if ! /usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -I "$BIN_DIR" \
  "$BIN_DIR/HarborCore.o" "$ACCESSOR" "${SOURCE_FILES[@]}" \
  scripts/verify-simple-style.swift -o "$APP/Contents/MacOS/HarborReplySimpleStyle" \
  > "$WORK_DIR/compile.log" 2>&1; then
  print -u2 'The external simple-style compile failed. No Mail recovery was started.'
  exit 1
fi
cp -R "$BIN_DIR/HarborReply_HarborReply.bundle" "$APP/Contents/Resources/"
cp -R "$RUNTIME_APP/Contents/Resources/python-arm64" "$APP/Contents/Resources/"
cp "$RUNTIME_APP/Contents/Resources/runtime.lock.json" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.harborreply.main-verification</string>
<key>CFBundleName</key><string>HarborReply Style Recovery</string>
<key>CFBundleExecutable</key><string>HarborReplySimpleStyle</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>明示開始した文体抽出の中断・再開検証でMailを読み取り、内容を含まない件数・一致判定・所要時間だけを報告します。</string>
</dict></plist>
PLIST
if ! /usr/bin/codesign --force --sign - --options runtime --entitlements scripts/HarborReply.entitlements "$APP" > "$WORK_DIR/sign.log" 2>&1; then
  print -u2 'The external simple-style signature failed.'
  exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict "$APP" >> "$WORK_DIR/sign.log" 2>&1; then
  print -u2 'The external simple-style signature check failed.'
  exit 1
fi
if [[ "$MODE" == --build-only ]]; then
  KEEP_BUILD=1
  print -r -- "$APP"
else
  HARBOR_STYLE_RECOVERY_STATE_PARENT="$WORK_DIR" \
    "$APP/Contents/MacOS/HarborReplySimpleStyle" --allow-real-mail ${CLOUD_FLAG:+$CLOUD_FLAG} 2>/dev/null &
  RECOVERY_PID="$!"
  wait "$RECOVERY_PID"
fi
