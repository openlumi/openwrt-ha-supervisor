#!/bin/sh
# Syntax check of every ucode source (compile only) in a throw-away Alpine container.
#   tools/check.sh [repo-root]
# Compile-only: it cannot catch runtime errors, but it catches broken edits before packaging.
set -eu
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
docker run --rm -v "$ROOT":/src:ro alpine:latest sh -c '
  apk add --no-cache ucode >/dev/null 2>&1 || { echo "cannot install ucode in the container"; exit 2; }
  rc=0; n=0
  for f in /src/files/usr/share/ucode/supervisor/*.uc /src/files/usr/sbin/*; do
    n=$((n+1))
    # `ucode -c` compiles a file as a script: drop import/export so module syntax is accepted
    sed "s/^export //; s/^import .*//" "$f" > /tmp/chk.uc
    if ! out=$(ucode -c -o /dev/null /tmp/chk.uc 2>&1); then
      echo "SYNTAX ERROR in ${f#/src/}:"; echo "$out" | head -8; rc=1
    fi
  done
  [ $rc -eq 0 ] && echo "syntax ok ($n files)"
  exit $rc
'
