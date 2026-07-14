#include "cancel_arbiter.h"

#include <atomic>
#include <cassert>
#include <chrono>
#include <thread>

namespace {

void callback_blocked_race() {
    using local_agent::CancelArbiter;
    using local_agent::CancelClaim;

    CancelArbiter arbiter;
    std::atomic<int> backend_cancel_count{0};
    std::atomic<bool> external_started{false};

    arbiter.callback_entered();
    std::thread external([&] {
        external_started = true;
        CancelClaim claim = arbiter.claim_from_external();
        assert(claim == CancelClaim::wait);
        claim = arbiter.wait_for_ownership_or_confirmation();
        if (claim == CancelClaim::owner) {
            backend_cancel_count += 1;
            arbiter.confirm(LOCAL_AGENT_STATUS_CANCELLED);
        }
        assert(arbiter.confirmed_status() == LOCAL_AGENT_STATUS_CANCELLED);
    });
    while (!external_started) std::this_thread::yield();
    std::this_thread::sleep_for(std::chrono::milliseconds(5));

    assert(arbiter.callback_returned(LOCAL_AGENT_STATUS_CANCELLED) == CancelClaim::owner);
    backend_cancel_count += 1;
    arbiter.confirm(LOCAL_AGENT_STATUS_CANCELLED);
    external.join();
    assert(backend_cancel_count == 1);
}

void backend_blocked_race() {
    using local_agent::CancelArbiter;
    using local_agent::CancelClaim;

    CancelArbiter arbiter;
    std::atomic<int> backend_cancel_count{0};
    assert(arbiter.claim_from_external() == CancelClaim::owner);
    backend_cancel_count += 1;
    arbiter.confirm(LOCAL_AGENT_STATUS_CANCELLED);
    assert(arbiter.claim_from_external() == CancelClaim::wait);
    assert(arbiter.wait_for_ownership_or_confirmation() == CancelClaim::wait);
    assert(backend_cancel_count == 1);
}

void terminal_race() {
    using local_agent::CancelArbiter;
    using local_agent::CancelClaim;

    for (int iteration = 0; iteration < 100; iteration += 1) {
        CancelArbiter arbiter;
        std::atomic<int> backend_cancel_count{0};
        std::thread terminal([&] { arbiter.mark_generation_terminal(); });
        std::thread cancel([&] {
            CancelClaim claim = arbiter.claim_from_external();
            if (claim == CancelClaim::owner) {
                backend_cancel_count += 1;
                arbiter.confirm(LOCAL_AGENT_STATUS_CANCELLED);
            }
        });
        terminal.join();
        cancel.join();
        assert(backend_cancel_count <= 1);
    }
}

} // namespace

int main() {
    using local_agent::CancelArbiter;
    using local_agent::CancelClaim;

    CancelArbiter callback_owned;
    callback_owned.callback_entered();
    assert(callback_owned.claim_from_external() == CancelClaim::wait);
    assert(callback_owned.callback_returned(LOCAL_AGENT_STATUS_CANCELLED) == CancelClaim::owner);
    callback_owned.confirm(LOCAL_AGENT_STATUS_CANCELLED);
    assert(callback_owned.wait_for_ownership_or_confirmation() == CancelClaim::wait);
    assert(callback_owned.confirmed_status() == LOCAL_AGENT_STATUS_CANCELLED);

    CancelArbiter external_owned;
    assert(external_owned.claim_from_external() == CancelClaim::owner);
    external_owned.confirm(LOCAL_AGENT_STATUS_CANCELLED);
    assert(external_owned.claim_from_external() == CancelClaim::wait);
    assert(external_owned.confirmed_status() == LOCAL_AGENT_STATUS_CANCELLED);

    CancelArbiter terminal;
    terminal.mark_generation_terminal();
    assert(terminal.claim_from_external() == CancelClaim::generation_terminal);
    assert(terminal.callback_returned(LOCAL_AGENT_STATUS_CANCELLED) == CancelClaim::generation_terminal);

    callback_blocked_race();
    backend_blocked_race();
    terminal_race();

    return 0;
}
