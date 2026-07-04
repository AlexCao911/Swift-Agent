#include "litert_quiesce_wait.h"

#include <cassert>
#include <vector>

namespace {

struct FakeStatus {
    int code = 0;
};

bool terminal_status(const FakeStatus &status) {
    return status.code == 0 || status.code == 2;
}

} // namespace

int main() {
    int repeated_attempts = 0;
    FakeStatus bounded = local_agent::wait_until_litert_quiesced<FakeStatus>(
        [&]() {
            repeated_attempts += 1;
            return FakeStatus{1};
        },
        terminal_status,
        3
    );
    assert(bounded.code == 1);
    assert(repeated_attempts == 3);

    int terminal_attempts = 0;
    std::vector<FakeStatus> statuses = {FakeStatus{1}, FakeStatus{1}, FakeStatus{2}};
    FakeStatus terminal = local_agent::wait_until_litert_quiesced<FakeStatus>(
        [&]() {
            return statuses[terminal_attempts++];
        },
        terminal_status,
        3
    );
    assert(terminal.code == 2);
    assert(terminal_attempts == 3);

    int one_attempt = 0;
    FakeStatus bounded_at_one = local_agent::wait_until_litert_quiesced<FakeStatus>(
        [&]() {
            one_attempt += 1;
            return FakeStatus{1};
        },
        terminal_status,
        0
    );
    assert(bounded_at_one.code == 1);
    assert(one_attempt == 1);

    return 0;
}
