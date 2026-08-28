#!/bin/bash
set -euo pipefail

out="${1:-$PWD/release-universal}"
out="$(mkdir -p "$(dirname "$out")" && cd "$(dirname "$out")" && pwd)/$(basename "$out")"
version="${ZETA_VERSION:-0.1.0}"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/zeta-universal.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

scripts/build-release.sh --arch arm64 --out "$temporary/arm64" --version "$version"
scripts/build-release.sh --arch x86_64 --out "$temporary/x86_64" --version "$version"
rm -rf "$out"
mkdir -p "$out/bin" "$out/share"
lipo -create "$temporary/arm64/bin/zeta" "$temporary/x86_64/bin/zeta" -output "$out/bin/zeta"
ln -s zeta "$out/bin/pi"
cp -R "$temporary/arm64/bin/Zeta_ZetaAI.bundle" "$out/bin/Zeta_ZetaAI.bundle"
cp -R "$temporary/arm64/share/zeta" "$out/share/zeta"
cp "$temporary/arm64/LICENSE" "$out/LICENSE"
cp "$temporary/arm64/README.md" "$out/README.md"
printf '%s\n' "$version" >"$out/VERSION"
(
  cd "$out"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 >SHA256SUMS
)
find "$out" -exec touch -h -t 200001010000 {} +
archive="${out%/}/zeta-${version}-macos-universal.tar.gz"
(
  cd "$out"
  printf '%s\n' LICENSE README.md SHA256SUMS VERSION bin share \
    | tar -cf - -T - \
    | gzip -n >"$archive"
)
echo "universal artifacts written to $out"
