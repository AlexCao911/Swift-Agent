import Foundation

package enum ProviderProbeWireEncoder {
    package static func modelDiscovery(
        encoderID: String,
        headers: [String: String] = [:]
    ) throws -> CloudWireRequest {
        try noBodyRequest(
            path: "/models",
            queryItems: [],
            encoderID: encoderID,
            requestClass: .discovery,
            headers: headers
        )
    }

    package static func accountValidation(
        encoderID: String,
        headers: [String: String] = [:]
    ) throws -> CloudWireRequest {
        try noBodyRequest(
            path: "/models",
            queryItems: [URLQueryItem(name: "limit", value: "1")],
            encoderID: encoderID,
            requestClass: .accountValidation,
            headers: headers
        )
    }

    package static func responsesModelValidation(
        encoderID: String,
        modelID: String
    ) throws -> CloudWireRequest {
        try modelValidation(
            path: "/responses",
            encoderID: encoderID,
            headers: [:],
            body: [
                "model": modelID,
                "input": "Reply with OK.",
                "max_output_tokens": 8,
                "stream": true,
                "store": false,
            ]
        )
    }

    package static func anthropicModelValidation(
        encoderID: String,
        modelID: String
    ) throws -> CloudWireRequest {
        try messagesModelValidation(
            encoderID: encoderID,
            modelID: modelID,
            headers: ["anthropic-version": "2023-06-01"]
        )
    }

    package static func miniMaxModelValidation(
        encoderID: String,
        modelID: String
    ) throws -> CloudWireRequest {
        try messagesModelValidation(
            encoderID: encoderID,
            modelID: modelID,
            headers: [:]
        )
    }

    package static func geminiModelValidation(
        encoderID: String,
        modelID: String
    ) throws -> CloudWireRequest {
        try modelValidation(
            path: "/interactions",
            encoderID: encoderID,
            headers: [:],
            body: [
                "model": modelID,
                "input": "Reply with OK.",
                "stream": true,
                "store": false,
                "generation_config": ["max_output_tokens": 8],
            ]
        )
    }

    package static func chatModelValidation(
        encoderID: String,
        modelID: String
    ) throws -> CloudWireRequest {
        try modelValidation(
            path: "/chat/completions",
            encoderID: encoderID,
            headers: [:],
            body: [
                "model": modelID,
                "messages": [["role": "user", "content": "Reply with OK."]],
                "max_tokens": 8,
                "stream": true,
            ]
        )
    }

    private static func messagesModelValidation(
        encoderID: String,
        modelID: String,
        headers: [String: String]
    ) throws -> CloudWireRequest {
        try modelValidation(
            path: "/messages",
            encoderID: encoderID,
            headers: headers,
            body: [
                "model": modelID,
                "messages": [["role": "user", "content": "Reply with OK."]],
                "max_tokens": 8,
                "stream": true,
            ]
        )
    }

    private static func noBodyRequest(
        path: String,
        queryItems: [URLQueryItem],
        encoderID: String,
        requestClass: CloudRequestClass,
        headers: [String: String]
    ) throws -> CloudWireRequest {
        var exactHeaders = headers
        exactHeaders["accept"] = "application/json"
        return try CloudWireRequest(
            method: "GET",
            path: path,
            queryItems: queryItems,
            headers: exactHeaders,
            body: nil,
            dataProvenance: .noUserData(
                presetEncoderID: encoderID,
                requestClass: requestClass
            )
        )
    }

    private static func modelValidation(
        path: String,
        encoderID: String,
        headers: [String: String],
        body: [String: Any]
    ) throws -> CloudWireRequest {
        var exactHeaders = headers
        exactHeaders["accept"] = "text/event-stream"
        exactHeaders["content-type"] = "application/json"
        return try CloudWireRequest(
            method: "POST",
            path: path,
            queryItems: [],
            headers: exactHeaders,
            body: try JSONSerialization.data(
                withJSONObject: body,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            dataProvenance: .noUserData(
                presetEncoderID: encoderID,
                requestClass: .modelValidation
            )
        )
    }
}
