#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
umask 077
if [[ "${1:-}" != --build-only && "${1:-}" != --allow-real-mail ]]; then
  print -u2 'Use --build-only to compile without Mail, or --allow-real-mail for a bounded read-only diagnostic.'
  exit 64
fi
MODE="$1"
shift
if [[ "$MODE" == --build-only && $# != 0 ]]; then exit 64; fi
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp/}harborreply-live-build.XXXXXX")"
APP="$WORK_DIR/HarborReplyLiveMail.app"
cleanup() { if [[ "$MODE" != --build-only ]]; then rm -rf "$WORK_DIR"; fi }
trap cleanup EXIT
/usr/bin/swift build > "$WORK_DIR/build.log" 2>&1
BIN_DIR="$(/usr/bin/swift build --show-bin-path)"
ACCESSOR="$(rg --files .build -g resource_bundle_accessor.swift | rg '/Debug/HarborReply[^/]*/DerivedSources/' | head -1)"
if [[ -z "$ACCESSOR" || ! -f "$BIN_DIR/HarborCore.o" ]]; then
  print -u2 'Live verification requires the host SwiftPM/Xcode debug object layout.'
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -I "$BIN_DIR" \
  "$BIN_DIR/HarborCore.o" "$ACCESSOR" \
  Sources/HarborReply/MailBridge.swift Sources/HarborReply/MailSelectionBridge.swift \
  Sources/HarborReply/MailBridgeResource.swift Sources/HarborReply/Failures.swift \
  Sources/HarborReply/Diagnostics.swift Sources/HarborReply/LocalWorker.swift \
  scripts/verify-live-mail.swift -o "$APP/Contents/MacOS/HarborReplyLiveMail" \
  > "$WORK_DIR/compile.log" 2>&1
cp -R "$BIN_DIR/HarborReply_HarborReply.bundle" "$APP/Contents/Resources/"
if [[ -n "${HARBOR_LIVE_RUNTIME_APP:-}" ]]; then
  if [[ ! -x "$HARBOR_LIVE_RUNTIME_APP/Contents/Resources/python-arm64/bin/python3" || ! -f "$HARBOR_LIVE_RUNTIME_APP/Contents/Resources/runtime.lock.json" ]]; then
    print -u2 'The specified app has no packaged Apple Silicon Python runtime.'
    exit 1
  fi
  cp -R "$HARBOR_LIVE_RUNTIME_APP/Contents/Resources/python-arm64" "$APP/Contents/Resources/"
  cp "$HARBOR_LIVE_RUNTIME_APP/Contents/Resources/runtime.lock.json" "$APP/Contents/Resources/"
else
  PYTHON="${HARBOR_PYTHON:-$(command -v python3)}"
  "$PYTHON" - "$APP/Contents/Resources/runtime.json" <<'PY'
import json, pathlib, sqlite3, sys
assert sys.version_info >= (3, 11)
sqlite3.connect(':memory:').execute('CREATE VIRTUAL TABLE x USING fts5(text)')
pathlib.Path(sys.argv[1]).write_text(json.dumps({'python': sys.executable}))
PY
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.harborreply.live-verification</string>
<key>CFBundleName</key><string>HarborReply Live Verification</string>
<key>CFBundleExecutable</key><string>HarborReplyLiveMail</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>明示開始した読み取り専用診断で、少量のMail情報を一時領域に取得し、件数と時間だけを報告します。</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --options runtime --entitlements scripts/HarborReply.entitlements "$APP" > "$WORK_DIR/sign.log" 2>&1
/usr/bin/codesign --verify --deep --strict "$APP" >> "$WORK_DIR/sign.log" 2>&1
if [[ "$MODE" == --build-only ]]; then
  print "Built external harness: $APP"
else
  "$APP/Contents/MacOS/HarborReplyLiveMail" --allow-real-mail "$@" 2>/dev/null
fi
