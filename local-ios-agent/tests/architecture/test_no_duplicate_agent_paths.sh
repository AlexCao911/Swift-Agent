#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
app="$root/apps/LocalAgentApp/LocalAgentApp"
project="$root/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj"

if rg -n 'runAgentLoop|SystemPromptBuilder|SwiftAnthropic|AnthropicService|OpenAIService' \
    "$app/ThirdParty/OpenMinis" -g '*.swift' >/dev/null; then
    echo "migrated OpenMinis code contains a second agent or provider path" >&2
    exit 1
fi

if rg -n 'AgentRuntimeService|ChatInteractionCoordinator' \
    "$app/Composition" "$app/App" >/dev/null; then
    echo "shipping composition still constructs the legacy Swift agent path" >&2
    exit 1
fi

if rg -n 'Minis\.xcodeproj|productName = Minis;|PRODUCT_BUNDLE_IDENTIFIER = com\.openminis' \
    "$project" >/dev/null; then
    echo "OpenMinis is configured as a shipping app" >&2
    exit 1
fi
