#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
"${HARBOR_SWIFT:-swift}" build --product HarborMailReader
"${HARBOR_PYTHON:-python3}" -m unittest discover -s Tests -v
"${HARBOR_SWIFT:-swift}" test
