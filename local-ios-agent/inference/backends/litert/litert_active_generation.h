#ifndef LOCAL_AGENT_LITERT_ACTIVE_GENERATION_H
#define LOCAL_AGENT_LITERT_ACTIVE_GENERATION_H

#include <condition_variable>
#include <functional>
#include <mutex>

namespace local_agent {

class LiteRTActiveGeneration {
public:
    using CancelCallback = std::function<void()>;

    void start(CancelCallback cancel);
    bool cancel();
    void finish();

private:
    std::mutex mutex_;
    std::condition_variable idle_;
    CancelCallback cancel_;
    bool active_ = false;
    int cancel_depth_ = 0;
};

} // namespace local_agent

#endif
