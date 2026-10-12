#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

action="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi

usage() {
  cat <<'HELP'
HarborReply repository workflows (Apple Silicon)
  nix run .#test                         Python + native Swift tests
  nix run .#build                        Signed developer .app in build/
  nix run .#package -- [--skip-build]     Standalone AirDrop ZIP in dist/
  nix run .#deploy                       Test, sign, notarize and publish Sparkle release
  nix run .#deploy -- --check            Read-only release prerequisite check
  nix run .#performance -- [arguments]   Synthetic scaling/complexity regression checks
  nix run .#performance -- --native-index [arguments] Whole-mail catalog scaling
  nix run .#diagnose                     Static environment diagnosis, no Mail events
  nix flake check                        Sandboxed Python + performance checks
  nix build .#worker                     Reproducible local Python worker
HELP
}

if [[ "$action" == help ]]; then
  usage
  exit 0
fi

: "${HARBOR_PYTHON:?Use nix run or nix develop to select the pinned Python runtime.}"
performance_script="scripts/performance.py"
if [[ "$action" == performance && "${1:-}" == --native-index ]]; then
  performance_script="scripts/index-performance.py"
  shift
fi

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  case "$action" in
    package) exec "$HARBOR_PYTHON" scripts/package-app.py "$@" ;;
    deploy) exec "$HARBOR_PYTHON" scripts/release.py "$@" ;;
    performance) exec "$HARBOR_PYTHON" "$performance_script" "$@" ;;
    *) usage; exit 0 ;;
  esac
fi

host_xcode() {
  if [[ "$(/usr/bin/uname -s)" != Darwin || "$(/usr/bin/uname -m)" != arm64 ]]; then
    echo 'Native HarborReply workflows require an Apple Silicon Mac.' >&2
    exit 2
  fi
  if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    echo 'Install Xcode and select it with xcode-select before native workflows.' >&2
    exit 2
  fi
  export HARBOR_SWIFT
  HARBOR_SWIFT="$(/usr/bin/xcrun --find swift)"
  export SDKROOT
  SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
  # Native Swift must use the selected Xcode compiler/linker, including inside a
  # Nix development shell. This only changes this command's child environment.
  unset NIX_CFLAGS_COMPILE NIX_LDFLAGS CC CXX LD AR
  export PATH="$(dirname "$HARBOR_SWIFT"):/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
}

case "$action" in
  test)
    [[ $# == 0 ]] || { usage >&2; exit 2; }
    host_xcode
    exec /bin/zsh scripts/test.sh
    ;;
  build)
    [[ $# == 0 ]] || { usage >&2; exit 2; }
    host_xcode
    exec /bin/zsh scripts/build-app.sh
    ;;
  package)
    host_xcode
    exec "$HARBOR_PYTHON" scripts/package-app.py "$@"
    ;;
  deploy)
    host_xcode
    exec "$HARBOR_PYTHON" scripts/release.py "$@"
    ;;
  performance)
    exec "$HARBOR_PYTHON" "$performance_script" "$@"
    ;;
  diagnose)
    [[ $# == 0 ]] || { usage >&2; exit 2; }
    host_xcode
    exec /bin/zsh scripts/diagnose.sh
    ;;
  *) usage >&2; exit 2 ;;
esac
