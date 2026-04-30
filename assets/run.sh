#!/usr/bin/env bash
set -euo pipefail

COPY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$COPY_DIR"

helper_tar=""
if [[ $# -gt 0 && "$1" != --* && "$1" == *.tar && -f "$1" ]]; then
  helper_tar="$1"
  shift
fi

if [[ -z "$helper_tar" ]]; then
  shopt -s nullglob
  helpers=(extract_me_*.tar)
  if (( ${#helpers[@]} > 0 )); then
    helper_tar="${helpers[$((${#helpers[@]} - 1))]}"
  elif [[ -f extract_me.tar ]]; then
    helper_tar="extract_me.tar"
  fi
fi

if [[ -z "$helper_tar" || ! -f "$helper_tar" ]]; then
  echo "ERROR: No extract_me helper archive found in $COPY_DIR" >&2
  echo "  Expected extract_me_*.tar or extract_me.tar" >&2
  exit 1
fi

echo "==> Extracting $helper_tar"
tar -xf "$helper_tar"

if [[ ! -f ./airgapped.sh ]]; then
  echo "ERROR: extract helper did not provide ./airgapped.sh" >&2
  exit 1
fi
chmod +x ./airgapped.sh 2>/dev/null || true

echo "==> Running airgapped load"
exec ./airgapped.sh --load "$@"
