#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Environment and static dictionary only. No Apple event is sent to Mail.
sw_vers
xcodebuild -version
"${HARBOR_SWIFT:-swift}" --version
"${HARBOR_PYTHON:-python3}" --version
"${HARBOR_PYTHON:-python3}" -c 'import sqlite3; c=sqlite3.connect(":memory:"); c.execute("CREATE VIRTUAL TABLE t USING fts5(x)"); print("SQLite", sqlite3.sqlite_version, "FTS5 available")'
/usr/bin/sdef /System/Applications/Mail.app | shasum -a 256
osacompile -o /tmp/harborreply-diagnostic.scpt Sources/HarborReply/Resources/MailBridge.applescript
print 'Mail script compiled. No Mail data read; no draft created; no runtime permission verified.'
