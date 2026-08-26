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
                throw LookupError.missingCredential("Add an OpenAI API key in Settings first.")
            }
            return try await checkWithChatGPT(apps: apps, prompt: prompt, apiKey: key)
        case .claude:
            guard let key = try await SecureCredentialStore.shared.load(.anthropicAPIKey), !key.isEmpty else {
                throw LookupError.missingCredential("Add an Anthropic API key in Settings first.")
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
                throw LookupError.missingCredential("Add a Google API key and Search Engine ID in Settings first.")
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

    static func identity(for app: InstalledApp) -> String {
        app.bundleID.isEmpty ? app.path : app.bundleID
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

        Check every macOS app below. Use official vendor release notes, appcasts, stores, or repositories.
        Search current sources. Never guess a version. Return one result for every supplied id.
        \(jsonInstruction)

        Installed apps:
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
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw LookupError.service(message ?? "Lookup failed with HTTP \(http.statusCode).")
        }
        return data
    }
}
