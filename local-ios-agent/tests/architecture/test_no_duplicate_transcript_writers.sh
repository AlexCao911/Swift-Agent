#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
app="$root/apps/LocalAgentApp/LocalAgentApp"

if rg -n 'chatStore\.(append|insert|remove|clear|delete|update)' \
    "$app" \
    -g '*.swift' \
    -g '!**/Runtime/ChatStoreProjectionApplier.swift' \
    -g '!**/ThirdParty/OpenMinis/ChatUI/ChatStore.swift' >/dev/null; then
    echo "Swift production code writes the projected transcript outside its applier" >&2
    exit 1
fi

rg -q 'coordinator\.send\(' "$app/Composition/AppContainer.swift"
rg -q 'ChatStoreProjectionApplier' "$app/Composition/AppContainer.swift"
