#!/bin/zsh
set -euo pipefail
if (( $# != 1 )); then
  print -u2 'Usage: scripts/watch-logs.sh user@friend-mac.local'
  exit 2
fi
HARBOR_HOST="$1"
if [[ ! "$HARBOR_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]*$ ]]; then
  print -u2 'Invalid SSH destination'; exit 2
fi
# Requires an already authorized SSH account and verified known-host key.
# No port, firewall, SSH server or remote file permissions are changed.
exec /usr/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$HARBOR_HOST" \
  'exec /usr/bin/tail -n 100 -F "$HOME/Library/Logs/HarborReply/diagnostics.jsonl"'
