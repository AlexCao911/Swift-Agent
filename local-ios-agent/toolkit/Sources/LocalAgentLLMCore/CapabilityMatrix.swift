import Foundation
import LocalAgentLLMContracts

public enum CapabilityMatrix {
    public static func resolve(
        observations: [CapabilityObservation],
        now: Date
    ) -> CapabilitySnapshot {
        let current = observations.filter { observation in
            observation.expiresAt.map { $0 > now } ?? true
        }
        let grouped = Dictionary(grouping: current, by: \.capabilityID)
        let resolved = grouped.mapValues(resolveCapability)
        return CapabilitySnapshot(capabilities: resolved)
    }

    private static func resolveCapability(
        _ observations: [CapabilityObservation]
    ) -> ResolvedCapability {
        var hasPositive = false
        var hasNegative = false
        var hasAuthoritativeNegative = false
        var verifiedBounds: [UInt64] = []

        for observation in observations {
            switch observation.value {
            case let .support(state):
                switch state {
                case .supported:
                    hasPositive = true
                case .unsupported:
                    hasNegative = true
                    hasAuthoritativeNegative = hasAuthoritativeNegative
                        || observation.authority == .authoritative
                case .unknown:
                    break
                }
            case let .verifiedUpperBound(bound):
                hasPositive = true
                if observation.authority != .advisory {
                    verifiedBounds.append(bound)
                }
            }
        }

        let support: SupportState
        if hasAuthoritativeNegative {
            support = .unsupported
        } else if hasPositive && hasNegative {
            support = .unknown
        } else if hasPositive {
            support = .supported
        } else if hasNegative {
            support = .unsupported
        } else {
            support = .unknown
        }

        return ResolvedCapability(
            support: support,
            verifiedUpperBound: support == .supported ? verifiedBounds.min() : nil
        )
    }
}
