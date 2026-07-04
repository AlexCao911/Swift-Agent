#ifndef LOCAL_AGENT_LITERT_QUIESCE_WAIT_H
#define LOCAL_AGENT_LITERT_QUIESCE_WAIT_H

namespace local_agent {

template <typename Result, typename WaitOnce, typename IsTerminal>
Result wait_until_litert_quiesced(
    WaitOnce wait_once,
    IsTerminal is_terminal,
    int max_non_terminal_waits
) {
    const int max_attempts = max_non_terminal_waits <= 0 ? 1 : max_non_terminal_waits;
    Result last_result = wait_once();
    if (is_terminal(last_result)) {
        return last_result;
    }

    for (int attempt = 1; attempt < max_attempts; ++attempt) {
        last_result = wait_once();
        if (is_terminal(last_result)) {
            return last_result;
        }
    }
    return last_result;
}

} // namespace local_agent

#endif
