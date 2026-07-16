public struct NormalizedToolResult: Codable, Equatable, Sendable {
    public let callID: String
    public let toolName: String
    public let result: CanonicalJSONValue
    public let isError: Bool
    public let dataClasses: Set<EgressDataClass>
    public let highestSensitivity: DataSensitivity

    public init(
        callID: String,
        toolName: String,
        result: CanonicalJSONValue,
        isError: Bool,
        dataClasses: Set<EgressDataClass>,
        highestSensitivity: DataSensitivity
    ) {
        self.callID = callID
        self.toolName = toolName
        self.result = result
        self.isError = isError
        if dataClasses.isEmpty || dataClasses.contains(.unknownData) {
            self.dataClasses = dataClasses.union([.unknownData])
            self.highestSensitivity = .unknown
        } else {
            self.dataClasses = dataClasses
            self.highestSensitivity = highestSensitivity
        }
    }
}
