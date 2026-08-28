#!/bin/bash
set -euo pipefail

prefix="${PREFIX:-$HOME/.local}"
source_dir="${1:-release-output}"
mkdir -p "$prefix/bin" "$prefix/share/zeta"
install -m 0755 "$source_dir/bin/zeta" "$prefix/bin/zeta"
rm -f "$prefix/bin/pi"
ln -s zeta "$prefix/bin/pi"
rm -rf "$prefix/bin/Zeta_ZetaAI.bundle"
cp -R "$source_dir/bin/Zeta_ZetaAI.bundle" "$prefix/bin/Zeta_ZetaAI.bundle"
if [[ -d "$source_dir/share/zeta" ]]; then
  rm -rf "$prefix/share/zeta"
  cp -R "$source_dir/share/zeta" "$prefix/share/zeta"
fi
echo "installed zeta and pi to $prefix/bin"
