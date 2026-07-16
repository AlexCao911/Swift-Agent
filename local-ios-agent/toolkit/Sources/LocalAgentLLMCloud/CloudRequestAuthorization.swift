package enum CloudRequestClass: String, Equatable, Sendable {
    case generation
    case discovery
    case accountValidation = "account_validation"
    case modelValidation = "model_validation"
}

package struct GenerationRequestSeal: Equatable, Sendable {
    package let generationAuthorizationID: String
    package let generationAuthorizationDigest: String
    package let disclosureDigest: String

    package init(
        generationAuthorizationID: String,
        generationAuthorizationDigest: String,
        disclosureDigest: String
    ) {
        self.generationAuthorizationID = generationAuthorizationID
        self.generationAuthorizationDigest = generationAuthorizationDigest
        self.disclosureDigest = disclosureDigest
    }
}

package struct NonGenerationRequestSeal: Equatable, Sendable {
    package let originApprovalRevision: UInt64
    package let presetEncoderID: String
    package let requestClass: CloudRequestClass

    package init(
        originApprovalRevision: UInt64,
        presetEncoderID: String,
        requestClass: CloudRequestClass
    ) {
        self.originApprovalRevision = originApprovalRevision
        self.presetEncoderID = presetEncoderID
        self.requestClass = requestClass
    }
}

package enum CloudRequestAuthorization: Equatable, Sendable {
    case generation(GenerationRequestSeal)
    case discovery(NonGenerationRequestSeal)
    case validation(NonGenerationRequestSeal)
}

package enum CloudWireDataProvenance: Equatable, Sendable {
    case generation
    case noUserData(presetEncoderID: String, requestClass: CloudRequestClass)
}
