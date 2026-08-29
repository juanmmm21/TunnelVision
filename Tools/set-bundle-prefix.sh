#!/usr/bin/env bash
#
# Replaces the reverse-DNS bundle prefix throughout the project.
#
#   Tools/set-bundle-prefix.sh com.yourname
#
# The identifiers in this repository are registered to the original author's Apple Developer
# account and will not provision under a different one. See docs/BUILDING.md.

set -euo pipefail

readonly OLD_PREFIX="com.juanmmm21"

if [[ $# -ne 1 ]]; then
    echo "usage: $(basename "$0") <new-prefix>        e.g. $(basename "$0") com.yourname" >&2
    exit 64
fi

readonly NEW_PREFIX="$1"

# Un prefijo mal formado no falla al sustituir: produce identificadores que Xcode rechaza mucho
# más tarde, con un error que no señala aquí. Se valida antes de tocar nada.
if [[ ! "$NEW_PREFIX" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z][A-Za-z0-9-]*)+$ ]]; then
    echo "error: '$NEW_PREFIX' is not a valid reverse-DNS prefix (expected something like com.yourname)" >&2
    exit 65
fi

if [[ "$NEW_PREFIX" == "$OLD_PREFIX" ]]; then
    echo "error: that is already the current prefix; nothing to do" >&2
    exit 65
fi

# El script se invoca desde cualquier sitio, pero opera sobre la raíz del repo.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Solo código y configuración. `docs/` queda fuera a propósito: sus menciones al prefijo original
# son narrativa (rutas de ejemplo, historia del proyecto), no identificadores que compilen.
# `mapfile` es de bash 4; macOS trae 3.2, que es el bash con el que esto se va a ejecutar.
find_sources() {
    find . \
        -path ./docs -prune -o \
        -path ./.git -prune -o \
        -type f \( -name '*.swift' -o -name '*.yml' -o -name '*.entitlements' \
                   -o -name '*.plist' -o -name '*.h' -o -name '*.c' -o -name '*.xcprivacy' \) \
        -print0
}

changed=0
while IFS= read -r -d '' file; do
    if grep -q "$OLD_PREFIX" "$file"; then
        # -i '' es la forma de BSD sed (macOS), que es donde esto se compila.
        sed -i '' "s/${OLD_PREFIX}/${NEW_PREFIX}/g" "$file"
        echo "  updated  ${file#./}"
        changed=$((changed + 1))
    fi
done < <(find_sources)

if [[ $changed -eq 0 ]]; then
    echo "No file contained '$OLD_PREFIX'. The prefix may already have been changed." >&2
    exit 1
fi

echo
echo "Rewrote $changed file(s): $OLD_PREFIX -> $NEW_PREFIX"
echo
echo "Next:"
echo "  1. Register the App IDs and the App Group under your account (docs/BUILDING.md, step 2)."
echo "  2. export DEVELOPMENT_TEAM=YOURTEAMID && xcodegen generate"
