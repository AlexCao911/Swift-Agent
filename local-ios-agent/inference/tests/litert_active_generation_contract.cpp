#include "litert_active_generation.h"

#include <cassert>
#include <atomic>
#include <chrono>
#include <thread>

int main() {
    local_agent::LiteRTActiveGeneration active;

    std::atomic<bool> cancel_entered{false};
    std::atomic<bool> cancel_can_return{false};
    std::atomic<bool> finish_returned{false};
    std::atomic<int> cancel_calls{0};

    active.start([&]() {
        cancel_calls.fetch_add(1);
        cancel_entered.store(true);
        while (!cancel_can_return.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    });

    std::thread canceller([&]() {
        assert(active.cancel());
    });

    while (!cancel_entered.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    std::thread finisher([&]() {
        active.finish();
        finish_returned.store(true);
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    assert(!finish_returned.load());
    assert(cancel_calls.load() == 1);

    cancel_can_return.store(true);
    canceller.join();
    finisher.join();

    assert(finish_returned.load());
    assert(!active.cancel());

    return 0;
}
