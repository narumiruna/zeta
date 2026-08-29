#!/bin/bash
set -euo pipefail

version="${ZETA_VERSION:-0.1.0}"
repo_root="$(git rev-parse --show-toplevel)"
checkout_status="$(git -C "$repo_root" status --porcelain --untracked-files=all)"
ignored_inputs="$(
  git -C "$repo_root" ls-files --others --ignored --exclude-standard -- \
    Sources Tests Examples docs
)"
if [[ -n "$checkout_status" || -n "$ignored_inputs" ]]; then
  echo "FAIL: source archives require a clean checkout without ignored release inputs." >&2
  exit 1
fi
out="${1:-$PWD/zeta-${version}-source.tar.gz}"
out="$(mkdir -p "$(dirname "$out")" && cd "$(dirname "$out")" && pwd)/$(basename "$out")"

commit="$(git rev-parse HEAD)"
git archive --format=tar --prefix="zeta-${version}/" "$commit" \
  | gzip -n >"$out"
printf '%s  %s\n' "$(shasum -a 256 "$out" | awk '{print $1}')" "$(basename "$out")"
