#include "cancel_arbiter.h"

namespace local_agent {

void CancelArbiter::callback_entered() {
    std::lock_guard<std::mutex> lock(mutex_);
    callback_in_flight_ = true;
}

CancelClaim CancelArbiter::callback_returned(LocalAgentStatus callback_status) {
    std::lock_guard<std::mutex> lock(mutex_);
    callback_in_flight_ = false;
    if (state_ == CancelState::generation_terminal) return CancelClaim::generation_terminal;
    if (state_ == CancelState::confirmed || state_ == CancelState::external_owned) {
        return CancelClaim::wait;
    }
    if (callback_status != LOCAL_AGENT_STATUS_OK) {
        state_ = CancelState::callback_owned;
        return CancelClaim::owner;
    }
    if (external_waiting_) {
        state_ = CancelState::external_owned;
        external_owner_available_ = true;
        condition_.notify_all();
    }
    return CancelClaim::wait;
}

CancelClaim CancelArbiter::claim_from_external() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ == CancelState::generation_terminal) return CancelClaim::generation_terminal;
    if (state_ == CancelState::confirmed || state_ == CancelState::callback_owned ||
        state_ == CancelState::external_owned) return CancelClaim::wait;
    if (callback_in_flight_) {
        external_waiting_ = true;
        state_ = CancelState::callback_owned;
        return CancelClaim::wait;
    }
    state_ = CancelState::external_owned;
    return CancelClaim::owner;
}

CancelClaim CancelArbiter::wait_for_ownership_or_confirmation() {
    std::unique_lock<std::mutex> lock(mutex_);
    condition_.wait(lock, [&] {
        return state_ == CancelState::confirmed ||
            state_ == CancelState::generation_terminal || external_owner_available_;
    });
    if (state_ == CancelState::generation_terminal) return CancelClaim::generation_terminal;
    if (external_owner_available_) {
        external_owner_available_ = false;
        return CancelClaim::owner;
    }
    return CancelClaim::wait;
}

void CancelArbiter::confirm(LocalAgentStatus status) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ == CancelState::generation_terminal || state_ == CancelState::confirmed) return;
    confirmed_status_ = status;
    state_ = CancelState::confirmed;
    external_owner_available_ = false;
    condition_.notify_all();
}

void CancelArbiter::mark_generation_terminal() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ == CancelState::not_requested) {
        state_ = CancelState::generation_terminal;
        external_owner_available_ = false;
        condition_.notify_all();
    }
}

LocalAgentStatus CancelArbiter::confirmed_status() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return confirmed_status_;
}

} // namespace local_agent
