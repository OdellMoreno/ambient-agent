import Foundation
import CryptoKit
import AmbientCore

// MARK: - LLM Client
// Unified client with semantic caching, embeddings, streaming, and fallbacks

// MARK: - Provider Configuration

enum LLMProvider: String, CaseIterable {
    case geminiFlash = "gemini-2.0-flash-exp"
    case claudeHaiku = "claude-3-5-haiku-20241022"
    case geminiEmbedding = "text-embedding-004"

    var costPer1MTokens: (input: Double, output: Double) {
        switch self {
        case .geminiFlash: return (0.075, 0.30)
        case .claudeHaiku: return (0.80, 4.00)
        case .geminiEmbedding: return (0.00, 0.00)  // Free tier
        }
    }
}

// MARK: - Retry Configuration

struct RetryConfig {
    let maxAttempts: Int
    let initialDelayMs: Int
    let backoffMultiplier: Double

    static let `default` = RetryConfig(maxAttempts: 3, initialDelayMs: 500, backoffMultiplier: 2.0)

    func delayMs(forAttempt attempt: Int) -> Int {
        let base = Double(initialDelayMs) * pow(backoffMultiplier, Double(attempt - 1))
        let jitter = base * 0.25 * Double.random(in: -1...1)
        return Int(min(base + jitter, 30000))
    }
}

// MARK: - Semantic Cache with Embeddings

actor SemanticCache {
    private var cache: [CacheEntry] = []
    private let ttl: TimeInterval = 7200  // 2 hours
    private let similarityThreshold: Float = 0.92  // High threshold to avoid incorrect hits
    private let maxEntries = 500

    struct CacheEntry {
        let queryHash: String
        let embedding: [Float]
        let response: String
        let timestamp: Date
    }

    // Exact match using hash (fast path)
    func getExact(_ key: String) -> String? {
        cleanOld()
        return cache.first { $0.queryHash == key }?.response
    }

    // Semantic match using embedding similarity (slower but catches similar queries)
    func getSemantic(embedding: [Float]) -> String? {
        cleanOld()

        var bestMatch: (entry: CacheEntry, similarity: Float)?

        for entry in cache {
            let similarity = cosineSimilarity(embedding, entry.embedding)
            if similarity >= similarityThreshold {
                if bestMatch == nil || similarity > bestMatch!.similarity {
                    bestMatch = (entry, similarity)
                }
            }
        }

        if let match = bestMatch {
            AmbientLogger.extraction.debug("Semantic cache hit with similarity: \(match.similarity)")
            return match.entry.response
        }
        return nil
    }

    func set(_ key: String, embedding: [Float], response: String) {
        // Evict old entries if at capacity
        if cache.count >= maxEntries {
            let sorted = cache.sorted { $0.timestamp < $1.timestamp }
            cache = Array(sorted.suffix(maxEntries - 100))
        }

        cache.append(CacheEntry(
            queryHash: key,
            embedding: embedding,
            response: response,
            timestamp: Date()
        ))
    }

    private func cleanOld() {
        let cutoff = Date().addingTimeInterval(-ttl)
        cache.removeAll { $0.timestamp < cutoff }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? dotProduct / denominator : 0
    }

    func stats() -> (count: Int, hitRate: String) {
        return (cache.count, "N/A")
    }
}

// MARK: - Embedding-Based Deduplicator

actor EmbeddingDeduplicator {
    private var processed: [(hash: String, embedding: [Float], date: Date)] = []
    private let window: TimeInterval = 86400  // 24 hours
    private let similarityThreshold: Float = 0.88  // Slightly lower for dedup

    func isDuplicate(_ content: String, embedding: [Float]? = nil) -> Bool {
        cleanOld()

        let hash = hashContent(content)

        // Fast path: exact hash match
        if processed.contains(where: { $0.hash == hash }) {
            return true
        }

        // Slow path: semantic similarity check
        if let emb = embedding {
            for entry in processed {
                if cosineSimilarity(emb, entry.embedding) >= similarityThreshold {
                    AmbientLogger.extraction.debug("Semantic duplicate detected")
                    return true
                }
            }
        }

        return false
    }

    func markProcessed(_ content: String, embedding: [Float]) {
        processed.append((hashContent(content), embedding, Date()))
    }

    private func hashContent(_ content: String) -> String {
        let data = Data(content.utf8)
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func cleanOld() {
        let cutoff = Date().addingTimeInterval(-window)
        processed.removeAll { $0.date < cutoff }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, nA: Float = 0, nB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            nA += a[i] * a[i]
            nB += b[i] * b[i]
        }
        let denom = sqrt(nA) * sqrt(nB)
        return denom > 0 ? dot / denom : 0
    }
}

// MARK: - Prompt Compressor

enum PromptCompressor {
    /// Compress long message content while preserving actionable information
    static func compress(_ content: String, maxTokens: Int = 2000) -> String {
        let words = content.split(separator: " ")

        // If already short enough, return as-is
        if words.count <= maxTokens {
            return content
        }

        // Extract key sentences (those with actionable keywords)
        let actionKeywords = Set([
            "meeting", "call", "tomorrow", "today", "deadline", "due", "remind",
            "schedule", "appointment", "confirm", "invite", "rsvp", "task",
            "urgent", "asap", "need", "monday", "tuesday", "wednesday", "thursday",
            "friday", "saturday", "sunday", "pm", "am", "noon", "evening"
        ])

        let sentences = content.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        var important: [String] = []
        var other: [String] = []

        for sentence in sentences {
            let lower = sentence.lowercased()
            let hasKeyword = actionKeywords.contains { lower.contains($0) }
            let hasTime = lower.range(of: #"\d{1,2}:\d{2}|\d{1,2}\s*(am|pm)"#, options: .regularExpression) != nil
            let hasDate = lower.range(of: #"\d{1,2}/\d{1,2}|\d{1,2}-\d{1,2}"#, options: .regularExpression) != nil

            if hasKeyword || hasTime || hasDate {
                important.append(sentence.trimmingCharacters(in: .whitespaces))
            } else {
                other.append(sentence.trimmingCharacters(in: .whitespaces))
            }
        }

        // Build compressed version: important sentences first
        var result = important.joined(separator: ". ")

        // Add other sentences until we hit the limit
        let remainingBudget = maxTokens - result.split(separator: " ").count
        if remainingBudget > 100 {
            let otherText = other.prefix(remainingBudget / 10).joined(separator: ". ")
            if !otherText.isEmpty {
                result += "\n\n[Additional context]: " + otherText
            }
        }

        let originalWords = content.split(separator: " ").count
        let compressedWords = result.split(separator: " ").count
        AmbientLogger.extraction.info("Compressed prompt: \(originalWords) → \(compressedWords) words")

        return result
    }

    /// Put important context at the beginning (avoid "lost in middle")
    static func optimizeContextPosition(_ systemPrompt: String, _ userContent: String, dateContext: String) -> String {
        // Structure: Date context FIRST, then key instructions, then content
        return """
        CRITICAL DATE CONTEXT (use this for all date calculations):
        \(dateContext)

        CONTENT TO ANALYZE:
        \(userContent)
        """
    }
}

// MARK: - Complexity Router

enum ContentComplexity {
    case simple, moderate, complex

    static func estimate(_ content: String) -> ContentComplexity {
        let words = content.split(separator: " ").count
        let hasMultipleDates = content.range(of: #"\d{1,2}[/-]\d{1,2}"#, options: .regularExpression) != nil
        let isAmbiguous = ["maybe", "possibly", "might"].contains { content.lowercased().contains($0) }
        let hasMultipleEvents = content.lowercased().components(separatedBy: "meeting").count > 2 ||
                               content.lowercased().components(separatedBy: "appointment").count > 2

        var score = 0
        if words > 500 { score += 2 } else if words > 200 { score += 1 }
        if hasMultipleDates { score += 1 }
        if isAmbiguous { score += 1 }
        if hasMultipleEvents { score += 1 }

        if score >= 3 { return .complex }
        if score >= 1 { return .moderate }
        return .simple
    }

    var providerChain: [LLMProvider] {
        switch self {
        case .simple: return [.geminiFlash]
        case .moderate: return [.geminiFlash, .claudeHaiku]
        case .complex: return [.geminiFlash, .claudeHaiku]
        }
    }
}

// MARK: - Unified LLM Client

actor LLMClient {
    private let semanticCache = SemanticCache()
    private let session: URLSession
    private let retryConfig: RetryConfig

    // Stats tracking
    private var totalCalls = 0
    private var cacheHits = 0
    private var semanticCacheHits = 0

    private var geminiKey: String {
        ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
            ?? ProcessInfo.processInfo.environment["GOOGLE_API_KEY"] ?? ""
    }

    private var claudeKey: String {
        ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    }

    init(retryConfig: RetryConfig = .default) {
        self.retryConfig = retryConfig
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    func call(
        systemPrompt: String,
        userPrompt: String,
        schema: [String: Any]? = nil,
        temperature: Double = 0.2,
        useCache: Bool = true,
        useCompression: Bool = false
    ) async throws -> String {
        totalCalls += 1

        // Optionally compress long prompts
        let finalUserPrompt = useCompression ? PromptCompressor.compress(userPrompt) : userPrompt

        let complexity = ContentComplexity.estimate(finalUserPrompt)
        return try await callWithFallback(
            complexity: complexity,
            systemPrompt: systemPrompt,
            userPrompt: finalUserPrompt,
            schema: schema,
            temperature: temperature,
            useCache: useCache
        )
    }

    func callWithFallback(
        complexity: ContentComplexity,
        systemPrompt: String,
        userPrompt: String,
        schema: [String: Any]? = nil,
        temperature: Double = 0.2,
        useCache: Bool = true
    ) async throws -> String {
        let cacheKey = hashContent("\(systemPrompt):\(userPrompt)")

        // Fast path: exact cache hit
        if useCache, let cached = await semanticCache.getExact(cacheKey) {
            cacheHits += 1
            AmbientLogger.extraction.debug("Exact cache hit")
            return cached
        }

        // Semantic cache: get embedding and check for similar queries
        var queryEmbedding: [Float]?
        if useCache {
            do {
                queryEmbedding = try await getEmbedding(for: userPrompt)
                if let emb = queryEmbedding, let cached = await semanticCache.getSemantic(embedding: emb) {
                    semanticCacheHits += 1
                    return cached
                }
            } catch {
                // Embedding failed, continue without semantic cache
                AmbientLogger.extraction.warning("Embedding failed: \(error.localizedDescription)")
            }
        }

        // Make the actual API call
        var lastError: Error?
        for provider in complexity.providerChain {
            do {
                let response = try await callWithRetry(
                    provider: provider,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    schema: schema,
                    temperature: temperature
                )

                // Cache the response
                if useCache {
                    var embedding = queryEmbedding ?? []
                    if embedding.isEmpty {
                        embedding = (try? await getEmbedding(for: userPrompt)) ?? []
                    }
                    await semanticCache.set(cacheKey, embedding: embedding, response: response)
                }

                return response
            } catch {
                lastError = error
                let providerName = provider.rawValue
                AmbientLogger.extraction.warning("Provider \(providerName) failed, trying fallback")
            }
        }
        throw lastError ?? LLMError.allProvidersFailed
    }

    // MARK: - Embeddings

    func getEmbedding(for text: String) async throws -> [Float] {
        guard !geminiKey.isEmpty else { throw LLMError.missingKey("GEMINI_API_KEY") }

        // Truncate for embedding (max ~2048 tokens)
        let truncated = String(text.prefix(8000))

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/text-embedding-004:embedContent?key=\(geminiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "models/text-embedding-004",
            "content": ["parts": [["text": truncated]]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        struct EmbeddingResponse: Decodable {
            struct Embedding: Decodable {
                let values: [Float]
            }
            let embedding: Embedding?
        }

        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        guard let values = decoded.embedding?.values else {
            throw LLMError.noResponse
        }
        return values
    }

    // MARK: - Stats

    func getStats() -> (total: Int, cacheHits: Int, semanticHits: Int, hitRate: Double) {
        let hitRate = totalCalls > 0 ? Double(cacheHits + semanticCacheHits) / Double(totalCalls) : 0
        return (totalCalls, cacheHits, semanticCacheHits, hitRate)
    }

    // MARK: - Retry Logic

    private func callWithRetry(
        provider: LLMProvider,
        systemPrompt: String,
        userPrompt: String,
        schema: [String: Any]?,
        temperature: Double
    ) async throws -> String {
        var lastError: Error?

        for attempt in 1...retryConfig.maxAttempts {
            do {
                return try await callProvider(
                    provider: provider,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    schema: schema,
                    temperature: temperature
                )
            } catch let error as LLMError where error.isRetryable {
                lastError = error
                if attempt < retryConfig.maxAttempts {
                    let delay = retryConfig.delayMs(forAttempt: attempt)
                    try await Task.sleep(for: .milliseconds(delay))
                }
            } catch {
                throw error
            }
        }
        throw lastError ?? LLMError.unknown
    }

    // MARK: - Provider Calls

    private func callProvider(
        provider: LLMProvider,
        systemPrompt: String,
        userPrompt: String,
        schema: [String: Any]?,
        temperature: Double
    ) async throws -> String {
        switch provider {
        case .geminiFlash:
            return try await callGemini(systemPrompt: systemPrompt, userPrompt: userPrompt, schema: schema, temperature: temperature)
        case .claudeHaiku:
            return try await callClaude(systemPrompt: systemPrompt, userPrompt: userPrompt, temperature: temperature)
        case .geminiEmbedding:
            throw LLMError.unknown  // Not a generation model
        }
    }

    private func callGemini(
        systemPrompt: String,
        userPrompt: String,
        schema: [String: Any]?,
        temperature: Double
    ) async throws -> String {
        guard !geminiKey.isEmpty else { throw LLMError.missingKey("GEMINI_API_KEY") }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=\(geminiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var genConfig: [String: Any] = ["temperature": temperature, "maxOutputTokens": 4096]
        if let schema = schema {
            genConfig["responseMimeType"] = "application/json"
            genConfig["responseSchema"] = schema
        }

        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": userPrompt]]]],
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "generationConfig": genConfig
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw LLMError.rateLimited }
            if http.statusCode >= 500 { throw LLMError.serverError(http.statusCode) }
        }

        struct GeminiResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text else {
            throw LLMError.noResponse
        }
        return text
    }

    private func callClaude(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double
    ) async throws -> String {
        guard !claudeKey.isEmpty else { throw LLMError.missingKey("ANTHROPIC_API_KEY") }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(claudeKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": LLMProvider.claudeHaiku.rawValue,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userPrompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw LLMError.rateLimited }
            if http.statusCode >= 500 { throw LLMError.serverError(http.statusCode) }
        }

        struct ClaudeResponse: Decodable {
            struct Content: Decodable { let type: String; let text: String? }
            let content: [Content]?
        }

        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        guard let text = decoded.content?.first(where: { $0.type == "text" })?.text else {
            throw LLMError.noResponse
        }
        return text
    }

    // MARK: - Helpers

    private func hashContent(_ content: String) -> String {
        let data = Data(content.utf8)
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

enum LLMError: Error, LocalizedError {
    case missingKey(String)
    case noResponse
    case rateLimited
    case serverError(Int)
    case allProvidersFailed
    case lowConfidence
    case unknown

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey(let key): return "\(key) not set"
        case .noResponse: return "No response from LLM"
        case .rateLimited: return "Rate limited"
        case .serverError(let code): return "Server error: \(code)"
        case .allProvidersFailed: return "All providers failed"
        case .lowConfidence: return "Low confidence extraction"
        case .unknown: return "Unknown error"
        }
    }
}
