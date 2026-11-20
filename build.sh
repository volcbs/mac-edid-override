#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$ROOT/build}"
mkdir -p "$DEST"
clang -std=c11 -Wall -Wextra -Werror -c "$ROOT/src/edid_policy.c" -o "$DEST/edid_policy.o"
clang -fmodules -fblocks -fobjc-arc -Wall -Wextra \
    -framework Foundation -framework CoreGraphics -framework IOKit -framework AppKit \
    -o "$DEST/edid_override" "$ROOT/src/edid_override.m" "$ROOT/src/profile_store.m" "$DEST/edid_policy.o"
