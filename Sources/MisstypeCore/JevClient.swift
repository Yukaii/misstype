import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession lives here on Linux
#endif

/// Result of a remote Jev evaluation request.
public struct JevEvaluationResult: Equatable, Sendable {
    public let pickedIndex: Int       // 1-based index (matching candidates array index + 1)
    public let pickedText: String
    public let confidence: Double
    public let latencyMs: Int

    public init(pickedIndex: Int, pickedText: String, confidence: Double, latencyMs: Int) {
        self.pickedIndex = pickedIndex
        self.pickedText = pickedText
        self.confidence = confidence
        self.latencyMs = latencyMs
    }
}

public enum JevClientError: LocalizedError, Equatable {
    case disabledOrMissingKey
    case emptyCandidates
    case invalidResponse(String)
    case httpError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .disabledOrMissingKey:
            return "Jev is disabled or API key is missing"
        case .emptyCandidates:
            return "No candidates provided for Jev evaluation"
        case .invalidResponse(let msg):
            return "Invalid Jev response: \(msg)"
        case .httpError(let code, let msg):
            return "HTTP \(code): \(msg)"
        }
    }
}

/// Native HTTP client for Vercel AI Gateway's typesafe-ai/jev model.
public enum JevClient {
    public static let endpoint = URL(string: "https://ai-gateway.vercel.sh/v4/ai/evaluation-model")!
    public static let defaultInstructions =
        "先檢查候選是否符合 phonetic_input 的注音音節與聲調；再使用 user_context、user_preferences（使用者過去親選的用字，優先於一般常見度）與 recent_commits 的話題連貫判斷。只在證據與上下文足以區分時選一項。若多個候選都同樣符合、或無法判斷使用者意圖，選最保守的候選，不要因為單純更常見就假裝確定。"

    /// Builds the URLRequest for evaluate without sending it (useful for testing & inspection).
    public static func buildRequest(
        config: JevConfig,
        rawKeys: String,
        evidence: [JevState.Evidence],
        candidates: [(text: String, score: Double, repairs: Int, unresolved: Int)],
        userContext: String = "",
        userPreferences: [[String: String]] = [],
        recentCommits: [String] = [],
        instructions: String = defaultInstructions,
        richContext: Bool = false,
        timeoutInterval: TimeInterval = 1.2
    ) throws -> URLRequest {
        guard config.canAttempt else {
            throw JevClientError.disabledOrMissingKey
        }
        guard !candidates.isEmpty else {
            throw JevClientError.emptyCandidates
        }

        let stateDict = JevState.build(
            rawKeys: rawKeys,
            evidence: evidence,
            candidates: candidates,
            userContext: userContext,
            userPreferences: userPreferences,
            recentCommits: recentCommits,
            richContext: richContext
        )
        let stateData = try JSONSerialization.data(withJSONObject: stateDict, options: [.sortedKeys])
        guard let stateString = String(data: stateData, encoding: .utf8) else {
            throw JevClientError.invalidResponse("Failed to encode state string")
        }

        var criteria: [String: String] = [:]
        for (idx, cand) in candidates.enumerated() {
            criteria[String(idx + 1)] = cand.text
        }

        let requestBody: [String: Any] = [
            "state": stateString,
            "questions": [
                "pick": [
                    "type": "choice",
                    "instructions": instructions,
                    "criteria": criteria
                ]
            ],
            "providerOptions": [:]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("4", forHTTPHeaderField: "ai-evaluation-model-specification-version")
        request.setValue("0.0.1", forHTTPHeaderField: "ai-gateway-protocol-version")
        request.setValue("api-key", forHTTPHeaderField: "ai-gateway-auth-method")
        request.setValue(config.model, forHTTPHeaderField: "ai-model-id")
        request.timeoutInterval = timeoutInterval
        request.httpBody = bodyData
        return request
    }

    /// Parses the raw JSON data returned by Vercel AI Gateway.
    public static func parseResponse(
        data: Data,
        candidates: [(text: String, score: Double, repairs: Int, unresolved: Int)],
        latencyMs: Int
    ) throws -> JevEvaluationResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JevClientError.invalidResponse("Root JSON is not a dictionary")
        }

        guard let answers = json["answers"] as? [String: Any],
              let pick = answers["pick"] as? [String: Any],
              let choiceStr = pick["choice"] as? String,
              let choiceIdx = Int(choiceStr) else {
            throw JevClientError.invalidResponse("Missing answers.pick.choice")
        }

        var confidence: Double = 0.0
        if let providerMetadata = json["providerMetadata"] as? [String: Any],
           let typesafe = providerMetadata["typesafe"] as? [String: Any],
           let confDict = typesafe["confidence"] as? [String: Any],
           let conf = confDict["pick"] as? Double {
            confidence = conf
        } else if let probabilities = pick["probabilities"] as? [String: Any],
                  let prob = probabilities[choiceStr] as? Double {
            confidence = prob
        }

        let candIndex = choiceIdx - 1
        guard candidates.indices.contains(candIndex) else {
            throw JevClientError.invalidResponse("choice index \(choiceIdx) out of bounds (\(candidates.count) candidates)")
        }

        let pickedText = candidates[candIndex].text
        return JevEvaluationResult(
            pickedIndex: choiceIdx,
            pickedText: pickedText,
            confidence: confidence,
            latencyMs: latencyMs
        )
    }

    /// Performs the asynchronous evaluation request.
    public static func evaluate(
        config: JevConfig,
        rawKeys: String,
        evidence: [JevState.Evidence],
        candidates: [(text: String, score: Double, repairs: Int, unresolved: Int)],
        userContext: String = "",
        userPreferences: [[String: String]] = [],
        recentCommits: [String] = [],
        instructions: String = defaultInstructions,
        richContext: Bool = false,
        timeoutInterval: TimeInterval = 1.2,
        session: URLSession = .shared
    ) async throws -> JevEvaluationResult {
        let request = try buildRequest(
            config: config,
            rawKeys: rawKeys,
            evidence: evidence,
            candidates: candidates,
            userContext: userContext,
            userPreferences: userPreferences,
            recentCommits: recentCommits,
            instructions: instructions,
            richContext: richContext,
            timeoutInterval: timeoutInterval
        )

        let t0 = DispatchTime.now()
        let (data, response) = try await session.data(for: request)
        let latencyMs = Int(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw JevClientError.invalidResponse("Response is not HTTPURLResponse")
        }
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? ""
            throw JevClientError.httpError(statusCode: httpResponse.statusCode, message: errorText)
        }

        return try parseResponse(data: data, candidates: candidates, latencyMs: latencyMs)
    }
}
