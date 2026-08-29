#!/bin/bash
set -euo pipefail

version="${ZETA_VERSION:-0.1.0}"
out="${1:-$PWD/zeta-${version}-source.tar.gz}"
out="$(mkdir -p "$(dirname "$out")" && cd "$(dirname "$out")" && pwd)/$(basename "$out")"

git diff --quiet
git diff --cached --quiet
commit="$(git rev-parse HEAD)"
git archive --format=tar --prefix="zeta-${version}/" "$commit" \
  | gzip -n >"$out"
printf '%s  %s\n' "$(shasum -a 256 "$out" | awk '{print $1}')" "$(basename "$out")"
