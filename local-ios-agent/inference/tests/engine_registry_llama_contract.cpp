#include "engine_registry.h"

#include <algorithm>
#include <cassert>

int main() {
    auto production_registry = local_agent::EngineRegistry::production();
    auto descriptors = production_registry.list();
    auto llama = std::find_if(descriptors.begin(), descriptors.end(), [](const auto &descriptor) {
        return descriptor.engine_id == "llama_cpp";
    });

    assert(llama != descriptors.end());
    assert(!llama->capabilities.supports_token_usage);
    assert(local_agent::engine_capabilities_json(*llama).find("\"supports_token_usage\":false") != std::string::npos);

    return 0;
}
