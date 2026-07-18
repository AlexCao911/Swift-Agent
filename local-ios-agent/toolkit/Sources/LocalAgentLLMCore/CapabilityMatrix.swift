import Foundation
import LocalAgentLLMContracts

public enum CapabilityResolutionPolicy: Equatable, Sendable {
    case providerNeutral
    case local
    case cloud
}

public enum CapabilityMatrix {
    public static func resolve(
        observations: [CapabilityObservation],
        now: Date
    ) -> CapabilitySnapshot {
        resolve(
            observations: observations,
            subject: .unscoped,
            policy: .providerNeutral,
            now: now
        )
    }

    public static func resolve(
        observations: [CapabilityObservation],
        subject: CapabilitySubject,
        policy: CapabilityResolutionPolicy,
        now: Date
    ) -> CapabilitySnapshot {
        let current = observations.filter { observation in
            (observation.expiresAt.map { $0 > now } ?? true)
                && observation.subject.encompasses(subject)
        }
        let grouped = Dictionary(grouping: current, by: \.capabilityID)
        let resolved = grouped.mapValues { resolveCapability($0, policy: policy) }
        let contributing = current.filter { contributes($0, under: policy) }
        return CapabilitySnapshot(
            capabilities: resolved,
            subject: subject,
            contributingObservationDigests: contributing.map(\.observationDigest).filter { !$0.isEmpty },
            nearestExpiry: contributing.compactMap(\.expiresAt).min()
        )
    }

    private static func resolveCapability(
        _ observations: [CapabilityObservation],
        policy: CapabilityResolutionPolicy
    ) -> ResolvedCapability {
        if policy == .cloud,
           let capabilityID = observations.first?.capabilityID,
           cloudAttachmentCapabilities.contains(capabilityID) {
            return ResolvedCapability(support: .unknown, verifiedUpperBound: nil)
        }
        let authoritativeNegative = observations.contains { observation in
            observation.authority == .authoritative
                && {
                    if case .support(.unsupported) = observation.value { return true }
                    return false
                }()
        }
        if authoritativeNegative {
            return ResolvedCapability(support: .unsupported, verifiedUpperBound: nil)
        }

        switch policy {
        case .providerNeutral:
            return resolveProviderNeutral(observations)
        case .local:
            return resolveLocal(observations)
        case .cloud:
            return resolveCloud(observations)
        }
    }

    private static func resolveLocal(
        _ observations: [CapabilityObservation]
    ) -> ResolvedCapability {
        let model = observations.filter { $0.dimension == .modelSupports }
        let engine = observations.filter { $0.dimension == .engineCanExecute }
        guard hasPositive(model), hasPositive(engine) else {
            return ResolvedCapability(support: .unknown, verifiedUpperBound: nil)
        }
        let bounds = (model + engine).compactMap { observation -> UInt64? in
            guard observation.authority != .advisory else { return nil }
            if case let .verifiedUpperBound(bound) = observation.value { return bound }
            return nil
        }
        return ResolvedCapability(support: .supported, verifiedUpperBound: bounds.min())
    }

    private static func hasPositive(_ observations: [CapabilityObservation]) -> Bool {
        observations.contains { observation in
            guard observation.authority == .authoritative else { return false }
            switch observation.value {
            case .support(.supported), .verifiedUpperBound:
                return true
            case .support(.unsupported), .support(.unknown):
                return false
            }
        }
    }

    private static func contributes(
        _ observation: CapabilityObservation,
        under policy: CapabilityResolutionPolicy
    ) -> Bool {
        if policy == .cloud,
           cloudAttachmentCapabilities.contains(observation.capabilityID) {
            return false
        }
        if observation.authority == .authoritative,
           case .support(.unsupported) = observation.value {
            return true
        }
        switch policy {
        case .providerNeutral:
            if case .support(.unknown) = observation.value { return false }
            return true
        case .local:
            guard observation.authority == .authoritative,
                  observation.dimension == .modelSupports
                    || observation.dimension == .engineCanExecute
            else { return false }
            if case .support(.unknown) = observation.value { return false }
            return true
        case .cloud:
            guard observation.authority != .advisory else { return false }
            if case .support(.unknown) = observation.value { return false }
            return observation.dimension == .adapterCanEncode
                || observation.dimension == .endpointSupports
                || observation.dimension == .modelSupports
        }
    }

    private static func resolveCloud(
        _ observations: [CapabilityObservation]
    ) -> ResolvedCapability {
        guard let capabilityID = observations.first?.capabilityID,
              !cloudAttachmentCapabilities.contains(capabilityID)
        else {
            return ResolvedCapability(support: .unknown, verifiedUpperBound: nil)
        }
        let adapter = observations.filter { $0.dimension == .adapterCanEncode }
        let endpoint = observations.filter { $0.dimension == .endpointSupports }
        let model = observations.filter { $0.dimension == .modelSupports }
        guard hasCloudPositive(adapter),
              hasCloudPositive(endpoint),
              hasCloudModelPositive(model, capabilityID: capabilityID)
        else {
            return ResolvedCapability(support: .unknown, verifiedUpperBound: nil)
        }
        let bounds = (adapter + endpoint + model).compactMap { observation -> UInt64? in
            guard observation.authority != .advisory else { return nil }
            if case let .verifiedUpperBound(value) = observation.value { return value }
            return nil
        }
        return ResolvedCapability(support: .supported, verifiedUpperBound: bounds.min())
    }

    private static func hasCloudPositive(_ observations: [CapabilityObservation]) -> Bool {
        observations.contains { observation in
            guard observation.authority != .advisory else { return false }
            switch observation.value {
            case .support(.supported), .verifiedUpperBound: return true
            case .support(.unsupported), .support(.unknown): return false
            }
        }
    }

    private static func hasCloudModelPositive(
        _ observations: [CapabilityObservation],
        capabilityID: String
    ) -> Bool {
        observations.contains { observation in
            let trustedSigned = observation.authority == .authoritative
                && observation.source == .signedCloudCatalog
            let probeMayProveRoutineText = observation.authority == .verified
                && observation.source == .connectivityProbe
                && cloudProbeProvableCapabilities.contains(capabilityID)
            guard trustedSigned || probeMayProveRoutineText else { return false }
            switch observation.value {
            case .support(.supported), .verifiedUpperBound: return true
            case .support(.unsupported), .support(.unknown): return false
            }
        }
    }

    private static func resolveProviderNeutral(
        _ observations: [CapabilityObservation]
    ) -> ResolvedCapability {
        var hasPositive = false
        var hasNegative = false
        var verifiedBounds: [UInt64] = []

        for observation in observations {
            switch observation.value {
            case let .support(state):
                switch state {
                case .supported: hasPositive = true
                case .unsupported: hasNegative = true
                case .unknown: break
                }
            case let .verifiedUpperBound(bound):
                hasPositive = true
                if observation.authority != .advisory { verifiedBounds.append(bound) }
            }
        }

        let support: SupportState
        if hasPositive && hasNegative {
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

private let cloudAttachmentCapabilities: Set<String> = [
    "audio_input", "document_input", "image_input", "video_input",
]

private let cloudProbeProvableCapabilities: Set<String> = [
    "streaming", "text_generation",
]
