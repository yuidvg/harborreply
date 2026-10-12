#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
umask 077

# Consent and option validation happen before SwiftPM or any app is launched.
if [[ "${1:-}" != --build-only && "${1:-}" != --allow-real-mail ]]; then
  print -u2 'Use --build-only, or --allow-real-mail [--allow-cloud-generation] [--preflight].'
  exit 64
fi
MODE="$1"
shift
if [[ "$MODE" == --build-only && $# != 0 ]]; then exit 64; fi
CLOUD_FLAG=0
PREFLIGHT_FLAG=0
for option in "$@"; do
  case "$option" in
    --allow-cloud-generation)
      if (( CLOUD_FLAG != 0 )); then exit 64; fi
      CLOUD_FLAG=1
      ;;
    --preflight)
      if (( PREFLIGHT_FLAG != 0 )); then exit 64; fi
      PREFLIGHT_FLAG=1
      ;;
    *) exit 64 ;;
  esac
done

if [[ ! -f scripts/verify-main-real.swift ]]; then
  print -u2 'The external main-flow verification source is not available.'
  exit 1
fi
RUNTIME_APP="${HARBOR_LIVE_RUNTIME_APP:-$PWD/dist/HarborReply-0.1.20/HarborReply.app}"
if [[ ! -x "$RUNTIME_APP/Contents/Resources/python-arm64/bin/python3" || ! -f "$RUNTIME_APP/Contents/Resources/runtime.lock.json" ]]; then
  print -u2 'The specified app has no packaged Apple Silicon Python runtime.'
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp/}harborreply-main-verification.XXXXXX")"
chmod 700 "$WORK_DIR"
APP="$WORK_DIR/HarborReplyMainVerification.app"
# Real-data state stays inside this wrapper-owned private tree. The external
# Swift runner receives this location only when it is invoked; --build-only
# leaves the tree to its caller, which must retain the same cleanup ownership.
STATE_PARENT="$WORK_DIR"
KEEP_BUILD=0
VERIFICATION_PID=""
cleanup() { if (( KEEP_BUILD == 0 )); then rm -rf "$WORK_DIR"; fi }
trap cleanup EXIT
stop_verification() {
  local task_exit="$1"
  trap - INT TERM
  if [[ -n "$VERIFICATION_PID" ]]; then
    kill -TERM "$VERIFICATION_PID" 2>/dev/null || true
    wait "$VERIFICATION_PID" 2>/dev/null || true
  fi
  exit "$task_exit"
}
trap 'stop_verification 130' INT
trap 'stop_verification 143' TERM
if ! /usr/bin/swift build > "$WORK_DIR/build.log" 2>&1; then
  print -u2 'The host Swift build failed. No Mail diagnostic was started.'
  exit 1
fi
BIN_DIR="$(/usr/bin/swift build --show-bin-path 2>> "$WORK_DIR/build.log")"
ACCESSOR="$(rg --files .build -g resource_bundle_accessor.swift | rg '/Debug/HarborReply[^/]*/DerivedSources/' | head -1)"
if [[ -z "$ACCESSOR" || ! -f "$BIN_DIR/HarborCore.o" || ! -d "$BIN_DIR/HarborReply_HarborReply.bundle" ]]; then
  print -u2 'Main-flow verification requires the host SwiftPM/Xcode debug object layout.'
  exit 1
fi
typeset -a SOURCE_FILES
while IFS= read -r source; do
  if [[ "${source:t}" != App.swift && "${source:t}" != AppUpdater.swift ]]; then SOURCE_FILES+=("$source"); fi
done < <(rg --files Sources/HarborReply -g '*.swift')
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if ! /usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -I "$BIN_DIR" \
  "$BIN_DIR/HarborCore.o" "$ACCESSOR" "${SOURCE_FILES[@]}" \
  scripts/verify-main-real.swift -o "$APP/Contents/MacOS/HarborReplyMainVerification" \
  > "$WORK_DIR/compile.log" 2>&1; then
  print -u2 'The external main-flow verification compile failed. No Mail diagnostic was started.'
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
<key>CFBundleName</key><string>HarborReply Main Verification</string>
<key>CFBundleExecutable</key><string>HarborReplyMainVerification</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>明示開始した読み取り専用検証でMailの主要処理を確認し、メール内容を含まない件数と所要時間だけを報告します。</string>
<key>NSMicrophoneUsageDescription</key><string>利用者が明示開始する音声入力にマイクを使用します。検証の事前確認だけでは録音を開始しません。</string>
<key>NSSpeechRecognitionUsageDescription</key><string>利用者が明示開始する日本語音声入力を端末内で文字起こしします。検証の事前確認だけでは音声認識を開始しません。</string>
</dict></plist>
PLIST
if ! /usr/bin/codesign --force --sign - --options runtime --entitlements scripts/HarborReply.entitlements "$APP" > "$WORK_DIR/sign.log" 2>&1; then
  print -u2 'The external main-flow verification signature failed.'
  exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict "$APP" >> "$WORK_DIR/sign.log" 2>&1; then
  print -u2 'The external main-flow verification signature check failed.'
  exit 1
fi
if [[ "$MODE" == --build-only ]]; then
  KEEP_BUILD=1
  print -r -- "$APP"
else
  HARBOR_MAIN_VERIFY_STATE_PARENT="$STATE_PARENT" \
    "$APP/Contents/MacOS/HarborReplyMainVerification" --allow-real-mail "$@" 2>/dev/null &
  VERIFICATION_PID="$!"
  wait "$VERIFICATION_PID"
fi
