#!/bin/zsh
set -euo pipefail
if (( $# != 1 )) || [[ "$1" != --build-only && "$1" != --allow-real-mail ]]; then
  print -u2 'Use --build-only or --allow-real-mail. No Mail read was started.'
  exit 64
fi
exec /bin/zsh "${0:A:h}/verify-simple-style.sh" "$@"
