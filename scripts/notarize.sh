#!/bin/bash
set -euo pipefail

archive="${1:?usage: notarize.sh <archive.zip>}"
profile="${ZETA_NOTARY_PROFILE:?set ZETA_NOTARY_PROFILE to a keychain profile}"
test -f "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
xcrun stapler staple "$archive"
