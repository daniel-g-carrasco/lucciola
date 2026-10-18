#!/usr/bin/env bash
# Does the gaming-native layer resolve against this image, the way
# `ujust lucciola-gaming-native` will layer it?
#
#   usage: gaming-native-resolve.sh <image-ref>
#
# Kept as the name build.yml, the gaming list and the changelog use; the
# check itself is layer-resolve.sh (2026-10-18, when the developer layer
# got the same check), whose header explains it.
set -euo pipefail
exec "$(dirname "$0")/layer-resolve.sh" "${1:?usage: gaming-native-resolve.sh <image-ref>}" gaming-native
