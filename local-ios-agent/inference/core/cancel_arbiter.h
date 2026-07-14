#ifndef LOCAL_AGENT_CANCEL_ARBITER_H
#define LOCAL_AGENT_CANCEL_ARBITER_H

#include "local_agent_inference.h"

#include <condition_variable>
#include <mutex>

namespace local_agent {

enum class CancelState {
    not_requested,
    callback_owned,
    external_owned,
    confirmed,
    generation_terminal,
};

enum class CancelClaim { owner, wait, generation_terminal };

class CancelArbiter {
public:
    void callback_entered();
    CancelClaim callback_returned(LocalAgentStatus callback_status);
    CancelClaim claim_from_external();
    CancelClaim wait_for_ownership_or_confirmation();
    void confirm(LocalAgentStatus status);
    void mark_generation_terminal();
    LocalAgentStatus confirmed_status() const;

private:
    mutable std::mutex mutex_;
    std::condition_variable condition_;
    CancelState state_ = CancelState::not_requested;
    bool callback_in_flight_ = false;
    bool external_waiting_ = false;
    bool external_owner_available_ = false;
    LocalAgentStatus confirmed_status_ = LOCAL_AGENT_STATUS_OK;
};

} // namespace local_agent

#endif
