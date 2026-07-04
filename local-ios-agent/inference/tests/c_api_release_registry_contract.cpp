#include "local_agent_inference.h"

#include <cassert>
#include <string>

int main() {
    char *engine_list_json = nullptr;
    assert(local_agent_engine_list(&engine_list_json) == LOCAL_AGENT_STATUS_OK);
    assert(engine_list_json != nullptr);
    std::string engine_list(engine_list_json);
    local_agent_string_free(engine_list_json);

    assert(engine_list.find("\"engine_id\":\"mock\"") == std::string::npos);

    LocalAgentEngineHandle *engine = nullptr;
    assert(local_agent_engine_create("mock", &engine) == LOCAL_AGENT_STATUS_ERROR);
    assert(engine == nullptr);
    return 0;
}
