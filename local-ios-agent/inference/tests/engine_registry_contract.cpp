#include "engine_registry.h"
#include "inference_engine.h"

#include <algorithm>
#include <cassert>
#include <memory>
#include <string>

int main(int argc, char **argv) {
    bool expect_litert_hidden = argc > 1 && std::string(argv[1]) == "--expect-litert-hidden";
    auto test_registry = local_agent::EngineRegistry::test();
    auto test_descriptors = test_registry.list();
    assert(std::any_of(test_descriptors.begin(), test_descriptors.end(), [](const auto &descriptor) {
        return descriptor.engine_id == "mock" && descriptor.test_only;
    }));

    auto production_registry = local_agent::EngineRegistry::production();
    auto production_descriptors = production_registry.list();
    assert(std::none_of(production_descriptors.begin(), production_descriptors.end(), [](const auto &descriptor) {
        return descriptor.engine_id == "mock";
    }));
    assert(production_registry.create("mock") == nullptr);
    if (expect_litert_hidden) {
        assert(std::none_of(production_descriptors.begin(), production_descriptors.end(), [](const auto &descriptor) {
            return descriptor.engine_id == "litert";
        }));
        assert(production_registry.find("litert") == nullptr);
    }

    const auto *mock = test_registry.find("mock");
    assert(mock != nullptr);
    assert(mock->capabilities.supports_streaming);
    assert(!mock->capabilities.supported_model_formats.empty());

    std::unique_ptr<local_agent::InferenceEngine> mock_engine = test_registry.create("mock");
    assert(mock_engine != nullptr);
    assert(local_agent::engine_descriptor_list_json(test_descriptors).find("\"mock\"") != std::string::npos);
    assert(local_agent::engine_capabilities_json(*mock).find("supports_streaming") != std::string::npos);

    return 0;
}
