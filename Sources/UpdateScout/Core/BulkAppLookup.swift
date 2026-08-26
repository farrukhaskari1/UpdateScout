import Foundation

enum BulkLookupProvider: String, CaseIterable, Identifiable, Sendable {
    case chatGPT
    case claude
    case google
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .google: "Google"
        case .custom: "Custom AI"
        }
    }
}

/// One-click endpoint + model pairs for the Custom AI provider.
///
/// Every entry speaks the OpenAI chat-completions shape, which is why one
/// provider covers all of them — the key still lives in the Keychain, and the
/// endpoint is just a settings field.
struct CustomAIPreset: Identifiable, Sendable {
    let name: String
    let endpoint: String
    let model: String

    var id: String { name }

    static let all: [CustomAIPreset] = [
        // deepseek-chat / deepseek-reasoner were retired on 2026-07-24; the
        // current IDs are deepseek-v4-flash and deepseek-v4-pro. Flash is the
        // cheaper default — swap to -pro for stronger reasoning.
        CustomAIPreset(
            name: "DeepSeek",
            endpoint: "https://api.deepseek.com/chat/completions",
            model: "deepseek-v4-flash"
        ),
        CustomAIPreset(
            name: "Groq",
            endpoint: "https://api.groq.com/openai/v1/chat/completions",
            model: "llama-3.3-70b-versatile"
        ),
        CustomAIPreset(
            name: "OpenRouter",
            endpoint: "https://openrouter.ai/api/v1/chat/completions",
            model: "deepseek/deepseek-v4-flash"
        ),
        CustomAIPreset(
            name: "Ollama",
            endpoint: "http://localhost:11434/v1/chat/completions",
            model: "llama3.1"
        )
    ]
}

struct AppLookupResult: Identifiable, Sendable {
    enum Status: String, Sendable {
        case updateAvailable
        case upToDate
        case unverified
    }

    let id: String
    let latestVersion: String?
    let status: Status
    let summary: String
    let sourceURL: URL?
}

enum BulkAppLookup {
    enum LookupError: LocalizedError {
        case missingCredential(String)
        case badResponse(String)
        case service(String)

        var errorDescription: String? {
            switch self {
            case .missingCredential(let message), .badResponse(let message), .service(let message): message
            }
        }
    }

    static func check(
        apps: [InstalledApp],
        provider: BulkLookupProvider,
        prompt: String,
        googleEngineID: String,
        anthropicModel: String,
        customEndpoint: String,
        customModel: String
    ) async throws -> [String: AppLookupResult] {
        switch provider {
        case .chatGPT:
            guard let key = try await SecureCredentialStore.shared.load(.openAIAPIKey), !key.isEmpty else {
                throw LookupError.missingCredential("ChatGPT is the selected service. Add an OpenAI API key in Settings, or switch Service to the one you configured.")
            }
            return try await checkWithChatGPT(apps: apps, prompt: prompt, apiKey: key)
        case .claude:
            guard let key = try await SecureCredentialStore.shared.load(.anthropicAPIKey), !key.isEmpty else {
                throw LookupError.missingCredential("Claude is the selected service. Add an Anthropic API key in Settings, or switch Service to the one you configured.")
            }
            let model = anthropicModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else {
                throw LookupError.missingCredential("Choose a Claude model in Settings first.")
            }
            return try await checkWithClaude(apps: apps, prompt: prompt, apiKey: key, model: model)
        case .google:
            guard let key = try await SecureCredentialStore.shared.load(.googleAPIKey), !key.isEmpty,
                  !googleEngineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw LookupError.missingCredential("Google is the selected service. Add a Google API key and Search Engine ID in Settings, or switch Service to the one you configured.")
            }
            return try await checkWithGoogle(
                apps: apps,
                prompt: prompt,
                apiKey: key,
                engineID: googleEngineID
            )
        case .custom:
            let endpoint = try validatedCustomEndpoint(customEndpoint)
            let model = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else {
                throw LookupError.missingCredential("Add the model name for your custom AI service in Settings first.")
            }
            let key = try await SecureCredentialStore.shared.load(.customAIAPIKey)
            return try await checkWithCustomAI(
                apps: apps,
                prompt: prompt,
                apiKey: key,
                endpoint: endpoint,
                model: model
            )
        }
    }

    /// Round-trip one trivial request to prove the key, endpoint, and model all
    /// work — before a real lookup spends tokens on 60 apps and fails on the
    /// last chunk.
    ///
    /// Returns a short success description; throws `LookupError` otherwise, so
    /// the caller can show the service's own message rather than a generic one.
    static func testConnection(
        provider: BulkLookupProvider,
        googleEngineID: String,
        anthropicModel: String,
        customEndpoint: String,
        customModel: String
    ) async throws -> String {
        switch provider {
        case .chatGPT:
            guard let key = try await SecureCredentialStore.shared.load(.openAIAPIKey), !key.isEmpty else {
                throw LookupError.missingCredential("ChatGPT is the selected service. Add an OpenAI API key in Settings, or switch Service to the one you configured.")
            }
            // Exercise the same endpoint and model the real lookup uses. A key
            // that can list models but has no access to gpt-5-mini would
            // otherwise pass the test and fail the lookup.
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-5-mini",
                "store": false,
                "input": "Reply with the single word: ok"
            ] as [String: Any])
            _ = try await responseData(for: request)
            return "OpenAI reachable, gpt-5-mini responded."

        case .claude:
            guard let key = try await SecureCredentialStore.shared.load(.anthropicAPIKey), !key.isEmpty else {
                throw LookupError.missingCredential("Claude is the selected service. Add an Anthropic API key in Settings, or switch Service to the one you configured.")
            }
            let model = anthropicModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else {
                throw LookupError.missingCredential("Choose a Claude model in Settings first.")
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 16,
                "messages": [["role": "user", "content": "Reply with the single word: ok"]]
            ] as [String: Any])
            _ = try await responseData(for: request)
            return "Anthropic reachable, \(model) responded."

        case .google:
            guard let key = try await SecureCredentialStore.shared.load(.googleAPIKey), !key.isEmpty else {
                throw LookupError.missingCredential("Google is the selected service. Add a Google API key in Settings, or switch Service to the one you configured.")
            }
            let engine = googleEngineID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !engine.isEmpty else {
                throw LookupError.missingCredential("Add a Google Search Engine ID in Settings first.")
            }
            var components = URLComponents(string: "https://customsearch.googleapis.com/customsearch/v1")!
            components.queryItems = [
                URLQueryItem(name: "key", value: key),
                URLQueryItem(name: "cx", value: engine),
                URLQueryItem(name: "num", value: "1"),
                URLQueryItem(name: "q", value: "macOS release notes")
            ]
            _ = try await responseData(for: URLRequest(url: components.url!))
            return "Google Custom Search reachable, key and engine accepted."

        case .custom:
            let endpoint = try validatedCustomEndpoint(customEndpoint)
            let model = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else {
                throw LookupError.missingCredential("Add the model name for your custom AI service in Settings first.")
            }
            let key = try await SecureCredentialStore.shared.load(.customAIAPIKey)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 16,
                "messages": [["role": "user", "content": "Reply with the single word: ok"]]
            ] as [String: Any])
            let data = try await responseData(for: request)

            // A 200 that isn't chat-completions shaped means the endpoint is
            // live but wrong — usually a base URL without /chat/completions.
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  message["content"] is String
            else {
                throw LookupError.badResponse(
                    "Connected, but the reply was not OpenAI chat-completions shaped. Check the URL ends in /chat/completions and the model name is right."
                )
            }
            return "\(endpoint.host ?? "Service") reachable, \(model) responded."
        }
    }

    /// A stable key for one app that is safe to send to a third party.
    ///
    /// Never the filesystem path: Spotlight discovery finds apps under `~`, so
    /// a path would carry the user's account name off the machine — which the
    /// confirmation dialog explicitly promises it does not.
    static func identity(for app: InstalledApp) -> String {
        guard app.bundleID.isEmpty else { return app.bundleID }
        return URL(fileURLWithPath: app.path).lastPathComponent
    }

    private static func checkWithChatGPT(
        apps: [InstalledApp], prompt: String, apiKey: String
    ) async throws -> [String: AppLookupResult] {
        var collected: [String: AppLookupResult] = [:]
        for start in stride(from: 0, to: apps.count, by: 20) {
            let chunk = Array(apps[start..<min(start + 20, apps.count)])
            let results = try await chatGPTChunk(chunk, prompt: prompt, apiKey: apiKey)
            for result in results { collected[result.id] = result }
        }
        return collected
    }

    private static func chatGPTChunk(
        _ apps: [InstalledApp], prompt: String, apiKey: String
    ) async throws -> [AppLookupResult] {
        let instructions = try lookupInstructions(apps: apps, prompt: prompt, requireJSON: false)
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "apps": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "id": ["type": "string"],
                            "latest_version": ["type": ["string", "null"]],
                            "status": ["type": "string", "enum": ["updateAvailable", "upToDate", "unverified"]],
                            "summary": ["type": "string"],
                            "source_url": ["type": ["string", "null"]]
                        ],
                        "required": ["id", "latest_version", "status", "summary", "source_url"]
                    ]
                ]
            ],
            "required": ["apps"]
        ]
        let body: [String: Any] = [
            "model": "gpt-5-mini",
            "store": false,
            "tools": [["type": "web_search"]],
            "input": instructions,
            "text": ["format": [
                "type": "json_schema",
                "name": "installed_app_versions",
                "strict": true,
                "schema": schema
            ]]
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await responseData(for: request)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]],
              let text = output.lazy.compactMap({ item -> String? in
                  guard item["type"] as? String == "message",
                        let content = item["content"] as? [[String: Any]]
                  else { return nil }
                  return content.first(where: { $0["type"] as? String == "output_text" })?["text"] as? String
              }).first,
              let resultData = text.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: resultData) as? [String: Any],
              let rows = parsed["apps"] as? [[String: Any]]
        else { throw LookupError.badResponse("ChatGPT returned an unreadable result.") }

        return rows.compactMap(parseResult)
    }

    private static func checkWithClaude(
        apps: [InstalledApp], prompt: String, apiKey: String, model: String
    ) async throws -> [String: AppLookupResult] {
        var collected: [String: AppLookupResult] = [:]
        for start in stride(from: 0, to: apps.count, by: 20) {
            let chunk = Array(apps[start..<min(start + 20, apps.count)])
            let results = try await claudeChunk(chunk, prompt: prompt, apiKey: apiKey, model: model)
            for result in results { collected[result.id] = result }
        }
        return collected
    }

    private static func claudeChunk(
        _ apps: [InstalledApp], prompt: String, apiKey: String, model: String
    ) async throws -> [AppLookupResult] {
        let instructions = try lookupInstructions(apps: apps, prompt: prompt, requireJSON: true)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8_192,
            "tools": [[
                "type": "web_search_20250305",
                "name": "web_search",
                "max_uses": min(max(apps.count, 3), 20)
            ]],
            "messages": [["role": "user", "content": instructions]]
        ]

        for _ in 0..<2 {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let data = try await responseData(for: request)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = root["content"] as? [[String: Any]]
            else { throw LookupError.badResponse("Claude returned an unreadable result.") }

            if root["stop_reason"] as? String == "pause_turn" {
                var messages = body["messages"] as? [[String: Any]] ?? []
                messages.append(["role": "assistant", "content": content])
                body["messages"] = messages
                continue
            }

            let text = content.compactMap { block in
                block["type"] as? String == "text" ? block["text"] as? String : nil
            }.joined(separator: "\n")
            return try parseLooseResults(text, service: "Claude")
        }
        throw LookupError.badResponse("Claude paused the search before returning results. Try again.")
    }

    private static func checkWithCustomAI(
        apps: [InstalledApp], prompt: String, apiKey: String?, endpoint: URL, model: String
    ) async throws -> [String: AppLookupResult] {
        var collected: [String: AppLookupResult] = [:]
        for start in stride(from: 0, to: apps.count, by: 20) {
            let chunk = Array(apps[start..<min(start + 20, apps.count)])
            let instructions = try lookupInstructions(apps: chunk, prompt: prompt, requireJSON: true)
            let body: [String: Any] = [
                "model": model,
                "messages": [["role": "user", "content": instructions]]
            ]
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let data = try await responseData(for: request)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String
            else { throw LookupError.badResponse("The custom AI service returned an unreadable result.") }
            for result in try parseLooseResults(text, service: "The custom AI service") {
                collected[result.id] = result
            }
        }
        return collected
    }

    static func validatedCustomEndpoint(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty
        else { throw LookupError.missingCredential("Add a valid custom AI endpoint in Settings first.") }
        let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        guard scheme == "https" || (scheme == "http" && localHosts.contains(host)) else {
            throw LookupError.service("Custom AI endpoints must use HTTPS. Plain HTTP is allowed only for a service running on this Mac.")
        }
        return url
    }

    private static func lookupInstructions(
        apps: [InstalledApp], prompt: String, requireJSON: Bool
    ) throws -> String {
        let inventory = apps.map {
            ["id": identity(for: $0), "name": $0.name, "installed_version": $0.shortVersion]
        }
        let data = try JSONSerialization.data(withJSONObject: inventory, options: [.sortedKeys])
        let inventoryJSON = String(decoding: data, as: UTF8.self)
        let jsonInstruction = requireJSON ? """

        Return ONLY valid JSON with this shape, without markdown fences:
        {"apps":[{"id":"supplied id","latest_version":"1.2.3 or null","status":"updateAvailable, upToDate, or unverified","summary":"brief evidence","source_url":"official https URL or null"}]}
        """ : ""
        return """
        \(prompt)

        Each app below is one this Mac could not identify an update mechanism for — no
        Sparkle feed, no package manager, no App Store receipt. The user has to update
        these by hand, so the useful answer is the current released version and where to
        get it.

        For every app: find the latest stable macOS release from the vendor's own release
        notes, appcast, store listing, or source repository. Compare it against
        installed_version and set status to updateAvailable, upToDate, or unverified.

        Rules:
        - Return exactly one result for every supplied id, even when unverified.
        - Never guess. If you cannot find an authoritative version, use
          latest_version: null and status "unverified" rather than inventing one.
        - Prefer stable releases. Ignore betas, release candidates, and nightlies
          unless the installed version is itself a prerelease.
        - Match the vendor's own version format so the two can be compared.
        - source_url must be the official download or release-notes page, so the user
          can complete the update manually.
        - Keep summary to one short sentence naming the evidence.
        \(jsonInstruction)

        Apps needing a manual check:
        \(inventoryJSON)
        """
    }

    static func parseLooseResults(_ text: String, service: String) throws -> [AppLookupResult] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last {
            json = String(trimmed[first...last])
        } else {
            throw LookupError.badResponse("\(service) did not return JSON results.")
        }
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["apps"] as? [[String: Any]]
        else { throw LookupError.badResponse("\(service) returned malformed JSON results.") }
        return rows.compactMap(parseResult)
    }

    private static func checkWithGoogle(
        apps: [InstalledApp], prompt: String, apiKey: String, engineID: String
    ) async throws -> [String: AppLookupResult] {
        try await withThrowingTaskGroup(of: AppLookupResult.self) { group in
            var iterator = apps.makeIterator()
            for _ in 0..<min(4, apps.count) {
                guard let app = iterator.next() else { break }
                group.addTask { try await googleResult(app, prompt: prompt, apiKey: apiKey, engineID: engineID) }
            }
            var results: [String: AppLookupResult] = [:]
            while let result = try await group.next() {
                results[result.id] = result
                if let app = iterator.next() {
                    group.addTask { try await googleResult(app, prompt: prompt, apiKey: apiKey, engineID: engineID) }
                }
            }
            return results
        }
    }

    private static func googleResult(
        _ app: InstalledApp, prompt: String, apiKey: String, engineID: String
    ) async throws -> AppLookupResult {
        var components = URLComponents(string: "https://customsearch.googleapis.com/customsearch/v1")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "cx", value: engineID),
            URLQueryItem(name: "num", value: "5"),
            URLQueryItem(name: "q", value: "\(app.name) latest stable macOS version official release \(prompt)")
        ]
        let data = try await responseData(for: URLRequest(url: components.url!))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = root?["items"] as? [[String: Any]] ?? []
        let first = items.first
        let combined = items.prefix(5).flatMap {
            [($0["title"] as? String) ?? "", ($0["snippet"] as? String) ?? ""]
        }.joined(separator: " ")
        let latest = firstVersion(in: combined, excluding: app.shortVersion)
        let status: AppLookupResult.Status
        if let latest {
            status = Version.isNewer(latest, than: app.shortVersion) ? .updateAvailable : .upToDate
        } else {
            status = .unverified
        }
        return AppLookupResult(
            id: identity(for: app),
            latestVersion: latest,
            status: status,
            summary: (first?["snippet"] as? String) ?? "Google did not return a verifiable release result.",
            sourceURL: (first?["link"] as? String).flatMap(URL.init(string:))
        )
    }

    static func firstVersion(in text: String, excluding installed: String) -> String? {
        let pattern = #"(?i)\bv?(\d+(?:\.\d+){1,3}(?:[-_][0-9A-Za-z.-]+)?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[valueRange])
        }.first(where: { $0 != installed })
    }

    private static func parseResult(_ row: [String: Any]) -> AppLookupResult? {
        guard let id = row["id"] as? String,
              let rawStatus = row["status"] as? String,
              let status = AppLookupResult.Status(rawValue: rawStatus),
              let summary = row["summary"] as? String
        else { return nil }
        return AppLookupResult(
            id: id,
            latestVersion: row["latest_version"] as? String,
            status: status,
            summary: summary,
            sourceURL: (row["source_url"] as? String).flatMap(URL.init(string:))
        )
    }

    private static func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LookupError.badResponse("The lookup service returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LookupError.service(describe(status: http.statusCode, body: data))
        }
        return data
    }

    /// Turn a failed HTTP response into something worth reading.
    ///
    /// Services disagree on error shapes — OpenAI and DeepSeek nest under
    /// `error.message`, some use a bare `message`, some return HTML or nothing
    /// at all. Falling straight through to "HTTP 401" hides the one sentence
    /// that would tell the user what to fix.
    static func describe(status: Int, body: Data) -> String {
        var detail: String?
        // `type`/`code` distinguish failures that share a status code — most
        // importantly 429, which OpenAI returns both for genuine rate limiting
        // and for an exhausted quota. Those need opposite advice.
        var kind: String?
        if let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = root["error"] as? [String: Any] {
                detail = error["message"] as? String
                kind = (error["type"] as? String) ?? (error["code"] as? String)
            }
            if detail == nil, let flat = root["message"] as? String {
                detail = flat
            }
            if detail == nil, let errorString = root["error"] as? String {
                detail = errorString
            }
        }
        if detail == nil {
            let raw = String(decoding: body, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A proxy or CDN error page is markup, not a message. Showing 200
            // characters of HTML in a status label helps nobody.
            if !raw.isEmpty, !raw.hasPrefix("<") {
                let firstLine = raw.split(separator: "\n").first.map(String.init) ?? raw
                detail = firstLine.count > 200 ? String(firstLine.prefix(200)) + "…" : firstLine
            }
        }

        let hint: String
        switch status {
        case 401:
            hint = " Check the API key is current — a revoked or regenerated key fails here, "
                 + "and keys are per-service, so an OpenAI key won't work against DeepSeek."
        case 402:
            hint = " This usually means the account has no remaining credit."
        case 403:
            hint = " The key is valid but not permitted to use this model."
        case 404:
            hint = " Check the endpoint URL — it should end in /chat/completions for an "
                 + "OpenAI-compatible service — and that the model name exists."
        case 429:
            // Quota exhaustion and rate limiting share this status but not the
            // remedy: waiting fixes one and never fixes the other.
            let quotaExhausted = kind == "insufficient_quota"
                || (detail?.localizedCaseInsensitiveContains("quota") ?? false)
                || (detail?.localizedCaseInsensitiveContains("billing") ?? false)
            hint = quotaExhausted
                ? " This is a billing problem, not a busy server — the account has no credit"
                    + " left, so waiting will not help. Add credit, or switch Service to a"
                    + " provider you still have quota with."
                : " Too many requests in a short window. Wait a moment and try again."
        default:
            hint = ""
        }

        return "HTTP \(status).\(detail.map { " \($0)" } ?? "")\(hint)"
    }
}
