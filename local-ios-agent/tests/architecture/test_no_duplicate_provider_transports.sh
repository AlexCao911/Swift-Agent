#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
providers="$root/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/Providers"

if rg -n 'URLSession|dataTask|SwiftAnthropic|AnthropicService|OpenAIService' \
    "$providers" -g '*.swift' >/dev/null; then
    echo "migrated provider UI contains an executable HTTP stack" >&2
    exit 1
fi

rg -q 'name: "LocalAgentLLMCloud"' "$root/toolkit/Package.swift"
