#!/bin/bash
set -euo pipefail

arch="$(uname -m)"
out="${PWD}/release-output"
version="${ZETA_VERSION:-0.1.0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) arch="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

out="$(mkdir -p "$(dirname "$out")" && cd "$(dirname "$out")" && pwd)/$(basename "$out")"

case "$arch" in
  arm64|x86_64) ;;
  *) echo "unsupported macOS architecture: $arch" >&2; exit 2 ;;
esac

rm -rf "$out"
mkdir -p "$out/bin" "$out/share/zeta"
version_source="Sources/ZetaCLI/BuildVersion.swift"
version_backup="$(mktemp "${TMPDIR:-/tmp}/zeta-version.XXXXXX")"
cp "$version_source" "$version_backup"
trap 'cp "$version_backup" "$version_source"; rm -f "$version_backup"' EXIT
printf 'enum BuildVersion { static let current = "%s" }\n' "$version" >"$version_source"
swift build -c release --arch "$arch" \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
bin_path="$(swift build -c release --arch "$arch" --show-bin-path)"
cp "$bin_path/zeta" "$out/bin/zeta"
ln -s zeta "$out/bin/pi"
cp -R "$bin_path/Zeta_ZetaAI.bundle" "$out/bin/Zeta_ZetaAI.bundle"
cp LICENSE "$out/LICENSE"
cp README.md "$out/README.md"
cp -R docs "$out/share/zeta/docs"
printf '%s\n' "$version" >"$out/VERSION"

if [[ -n "${ZETA_CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp \
    --sign "$ZETA_CODESIGN_IDENTITY" "$out/bin/zeta"
fi

(
  cd "$out"
  find . -type f ! -name SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 shasum -a 256 >SHA256SUMS
)

find "$out" -exec touch -h -t 200001010000 {} +
archive="${out%/}/zeta-${version}-macos-${arch}.tar.gz"
(
  cd "$out"
  printf '%s\n' LICENSE README.md SHA256SUMS VERSION bin share \
    | tar -cf - -T - \
    | gzip -n >"$archive"
)

echo "release artifact: ${out%/}/zeta-${version}-macos-${arch}.tar.gz"
