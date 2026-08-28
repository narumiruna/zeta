#!/bin/bash
set -euo pipefail

prefix="${PREFIX:-$HOME/.local}"
rm -f "$prefix/bin/zeta" "$prefix/bin/pi"
rm -rf "$prefix/bin/Zeta_ZetaAI.bundle" "$prefix/share/zeta"
echo "removed zeta and pi from $prefix"
