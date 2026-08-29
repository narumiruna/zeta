#!/bin/bash
set -euo pipefail

source_root="${PI_SOURCE_ROOT:-/Users/narumi/workspace/pi}"
source_commit="56700d42ed65a94a80af7376adb19a9298065164"
output="Sources/ZetaAI/Resources/model-catalog.json"
manifest="Sources/ZetaAI/Resources/model-catalog.manifest.json"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/zeta-model-catalog.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

git clone --quiet --no-hardlinks "$source_root" "$temporary/pi"
git -C "$temporary/pi" checkout --quiet --detach "$source_commit"
npm --prefix "$temporary/pi" ci --ignore-scripts
npm --prefix "$temporary/pi" run hydrate:model-data
npm --prefix "$temporary/pi" run generate:model-catalog

candidate="$temporary/pi/.artifacts/model-catalog/models.json"
mkdir -p "$(dirname "$output")"
cp "$candidate" "$output"

sha="$(shasum -a 256 "$output" | awk '{print $1}')"
providers="$(jq 'keys|length' "$output")"
models="$(jq '[.[]|keys|length]|add' "$output")"
cat >"$manifest" <<EOF
{
  "schemaVersion": 1,
  "sourceCommit": "$source_commit",
  "providerCount": $providers,
  "modelCount": $models,
  "sha256": "$sha"
}
EOF

echo "generated $models models across $providers providers at $source_commit"
