#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
rm -rf .build/release/HarborReply_HarborReply.bundle
"${HARBOR_SWIFT:-swift}" build -c release -Xlinker -rpath -Xlinker @executable_path/../Frameworks
APP="$PWD/build/HarborReply.app"
SIGN_OPTIONS=()
if [[ "${HARBOR_SIGN_IDENTITY:--}" != "-" ]]; then SIGN_OPTIONS=(--options runtime --timestamp); fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HarborReply "$APP/Contents/MacOS/HarborReply"
cp .build/release/HarborMailReader "$APP/Contents/MacOS/HarborMailReader"
codesign --force --sign "${HARBOR_SIGN_IDENTITY:--}" "${SIGN_OPTIONS[@]}" "$APP/Contents/MacOS/HarborMailReader"
rm -rf "$APP/Contents/Resources/HarborReply_HarborReply.bundle"
cp -R .build/release/HarborReply_HarborReply.bundle "$APP/Contents/Resources/"
cp scripts/Info.plist "$APP/Contents/Info.plist"
HARBOR_PYTHON="${HARBOR_PYTHON:-$(command -v python3)}"
"$HARBOR_PYTHON" - "$APP/Contents/Resources/runtime.json" <<'PY'
import json, sys, sqlite3
from pathlib import Path
assert sys.version_info >= (3, 11), 'Python 3.11+ is required for packaged builds'
sqlite3.connect(':memory:').execute('CREATE VIRTUAL TABLE x USING fts5(text)')
Path(sys.argv[1]).write_text(json.dumps({'python': sys.executable, 'version': sys.version.split()[0], 'sqlite': sqlite3.sqlite_version}))
PY
"$HARBOR_PYTHON" scripts/embed-sparkle.py "$APP"
codesign --force --sign "${HARBOR_SIGN_IDENTITY:--}" "${SIGN_OPTIONS[@]}" --entitlements scripts/HarborReply.entitlements "$APP"
codesign --verify --deep --strict "$APP"
print "Built: $APP"
