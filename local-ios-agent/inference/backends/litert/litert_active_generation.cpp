#include "litert_active_generation.h"

#include <utility>

namespace local_agent {

void LiteRTActiveGeneration::start(CancelCallback cancel) {
    std::unique_lock<std::mutex> lock(mutex_);
    idle_.wait(lock, [&]() {
        return cancel_depth_ == 0;
    });
    cancel_ = std::move(cancel);
    active_ = true;
}

bool LiteRTActiveGeneration::cancel() {
    CancelCallback cancel;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_ || !cancel_) {
            return false;
        }
        cancel = cancel_;
        cancel_depth_ += 1;
    }

    try {
        cancel();
    } catch (...) {
        std::lock_guard<std::mutex> lock(mutex_);
        cancel_depth_ -= 1;
        idle_.notify_all();
        throw;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    cancel_depth_ -= 1;
    idle_.notify_all();
    return true;
}

void LiteRTActiveGeneration::finish() {
    std::unique_lock<std::mutex> lock(mutex_);
    active_ = false;
    idle_.wait(lock, [&]() {
        return cancel_depth_ == 0;
    });
    cancel_ = nullptr;
}

} // namespace local_agent
