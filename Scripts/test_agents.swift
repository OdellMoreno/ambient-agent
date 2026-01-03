#!/usr/bin/env swift
//
// test_agents.swift
// Three-Agent Pipeline Integration Test
//
// Tests the message extraction pipeline with sample conversation data.
// Uses Gemini Flash for cost-effective processing.
//
// Usage:
//   export GEMINI_API_KEY="your-key"
//   swift Scripts/test_agents.swift
//

import Foundation

// MARK: - Configuration

/// API key loaded from environment variable for security
let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""

/// Gemini model to use - Flash is fast and cost-effective
let model = "gemini-2.0-flash-exp"

// MARK: - Sample Test Data

/// Sample conversations for testing the pipeline
/// Format mimics iMessage export with timestamps, senders, and content
let testMessages = """
## Conversation with Sarah

[9:15 AM] Sarah: Hey! Want to grab coffee tomorrow?
[9:16 AM] Me: Sure! What time works for you?
[9:18 AM] Sarah: How about 2pm at Blue Bottle on Market Street?
[9:19 AM] Me: Perfect, see you there!

## Conversation with Mom

[2:30 PM] Mom: Don't forget Dad's birthday dinner on Saturday at 6pm
[2:31 PM] Me: Got it! Is it at the usual Italian place?
[2:32 PM] Mom: Yes, Trattoria Roma. Can you pick up the cake from Sweet Things before?
[2:33 PM] Me: Will do!
"""

// MARK: - Gemini API Client

/// Calls the Gemini API with a system prompt and user prompt
/// - Parameters:
///   - systemPrompt: Instructions for the model's behavior
///   - userPrompt: The actual content to process
/// - Returns: The model's text response
func callGemini(systemPrompt: String, userPrompt: String) async throws -> String {
    guard !apiKey.isEmpty else {
        throw NSError(domain: "Config", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "GEMINI_API_KEY environment variable not set"])
    }

    let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
        "contents": [
            ["role": "user", "parts": [["text": userPrompt]]]
        ],
        "systemInstruction": [
            "parts": [["text": systemPrompt]]
        ],
        "generationConfig": [
            "temperature": 0.2,  // Low temperature for consistent extraction
            "maxOutputTokens": 2048
        ]
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)

    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
        let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
        throw NSError(domain: "GeminiAPI", code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: errorText])
    }

    // Parse the Gemini response structure
    struct Response: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                }
                let parts: [Part]?
            }
            let content: Content?
        }
        let candidates: [Candidate]?
    }

    let decoded = try JSONDecoder().decode(Response.self, from: data)
    guard let text = decoded.candidates?.first?.content?.parts?.first?.text else {
        throw NSError(domain: "GeminiAPI", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "No text in response"])
    }

    return text
}

// MARK: - Agent 1: Story Agent

/// Converts raw message conversations into a coherent narrative summary.
/// This makes it easier for the extractor to identify events and tasks.
func runStoryAgent() async throws -> String {
    print("📖 Running Story Agent...")

    let systemPrompt = """
    You are a helpful assistant that reads message conversations and writes clear, concise narrative summaries.
    Focus on events, plans, commitments, and action items mentioned.
    Write in third person, past tense. Be concise but capture important details.
    """

    let userPrompt = """
    Date: Monday, December 30, 2024

    Here are today's conversations:

    \(testMessages)

    Write a narrative summary focusing on any events, plans, or tasks mentioned.
    """

    let story = try await callGemini(systemPrompt: systemPrompt, userPrompt: userPrompt)
    print("✅ Story Agent complete\n")
    return story
}

// MARK: - Agent 2: Extractor Agent

/// Extracts structured events and tasks from the narrative.
/// Returns JSON with rough dates that need to be resolved.
func runExtractorAgent(story: String) async throws -> String {
    print("🔍 Running Extractor Agent...")

    let systemPrompt = """
    You extract events and tasks from narrative text.

    For each item, identify:
    - title: Short descriptive title
    - type: "event" or "task"
    - rough_date: Date as mentioned ("tomorrow", "Saturday", etc.)
    - rough_time: Time if mentioned ("2pm", "6pm", etc.)
    - people: Who's involved
    - location: Where, if mentioned
    - confidence: "high", "medium", or "low"

    Return ONLY a JSON array, no other text.
    """

    let userPrompt = """
    Extract events and tasks from this story:

    \(story)

    Return as JSON array:
    [{"title": "...", "type": "event", "rough_date": "...", "rough_time": "...", "people": [...], "location": "...", "confidence": "..."}]
    """

    let extracted = try await callGemini(systemPrompt: systemPrompt, userPrompt: userPrompt)
    print("✅ Extractor Agent complete\n")
    return extracted
}

// MARK: - Agent 3: Formatter Agent

/// Resolves relative dates to absolute ISO 8601 timestamps.
/// Outputs calendar-ready JSON for the EventKit integration.
func runFormatterAgent(extracted: String) async throws -> String {
    print("📅 Running Formatter Agent...")

    // Build date context for the model
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
    let today = dateFormatter.string(from: Date())

    let systemPrompt = """
    You convert informal dates to exact ISO 8601 dates.

    TODAY IS: \(today)

    Reference:
    - "tomorrow" = day after today
    - "Saturday" = upcoming Saturday

    Return JSON with exact dates in format: YYYY-MM-DDTHH:MM:SSZ
    """

    let userPrompt = """
    Convert these items to calendar-ready format:

    \(extracted)

    Return JSON:
    {
      "events": [{"title": "...", "start_date": "2025-01-01T14:00:00Z", "end_date": "...", "location": "...", "attendees": [...]}],
      "tasks": [{"title": "...", "due_date": "...", "priority": "..."}]
    }

    Return ONLY JSON, no other text.
    """

    let formatted = try await callGemini(systemPrompt: systemPrompt, userPrompt: userPrompt)
    print("✅ Formatter Agent complete\n")
    return formatted
}

// MARK: - Main Entry Point

func runTests() async {
    print("🚀 Testing Three-Agent Pipeline with Gemini Flash\n")
    print(String(repeating: "=", count: 60))

    do {
        // Agent 1: Convert messages to narrative
        let story = try await runStoryAgent()
        print("📖 STORY:\n\(story)\n")
        print(String(repeating: "-", count: 60))

        // Agent 2: Extract events and tasks
        let extracted = try await runExtractorAgent(story: story)
        print("🔍 EXTRACTED:\n\(extracted)\n")
        print(String(repeating: "-", count: 60))

        // Agent 3: Format with resolved dates
        let formatted = try await runFormatterAgent(extracted: extracted)
        print("📅 FORMATTED:\n\(formatted)\n")
        print(String(repeating: "=", count: 60))

        print("\n✅ Pipeline test completed successfully!")

    } catch {
        print("❌ Error: \(error.localizedDescription)")
    }
}

// Run the async test
let semaphore = DispatchSemaphore(value: 0)
Task {
    await runTests()
    semaphore.signal()
}
semaphore.wait()
