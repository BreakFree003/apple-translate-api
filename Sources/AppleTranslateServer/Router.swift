import Foundation

struct SimpleTranslateRequest: Decodable, Sendable {
    var text: String?
    var q: String?
    var source: String?
    var from: String?
    var target: String?
    var to: String?
    var lang: String?

    var payload: String? {
        for candidate in [text, q] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return candidate }
        }
        return nil
    }

    var explicitSource: String? { source ?? from }
    var explicitTarget: String? { target ?? to ?? lang }
}

struct SimpleTranslateResponse: Encodable {
    let translation: String
    let source_language: String
    let target_language: String
    let skipped: Bool
}

struct HealthResponse: Encodable {
    let status = "ok"
    let model: String
    let server: String
    let uptime_seconds: Int
    let default_source: String
    let default_target: String
    let smart_skip: Bool
    let source_mode: String
}

struct LanguagesResponse: Encodable {
    let catalog: [Entry]
    let system_supported: [String]
    let default_target: String
    let pair_status: String?

    struct Entry: Encodable {
        let id: String
        let english: String
        let chinese: String
    }
}

/// 把一次 HTTP 请求路由到对应的处理函数。
final class Router: Sendable {
    private let config: Config
    private let engine: TranslationEngine
    private let startedAt = Date()

    init(config: Config, engine: TranslationEngine) {
        self.config = config
        self.engine = engine
    }

    func handle(_ request: HTTPRequest, _ writer: any ResponseWriter) async {
        if request.method == "OPTIONS" {
            await writer.send(HTTPResponse(status: 204))
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/health"):
            await handleHealth(writer)
        case ("GET", "/v1/models"), ("GET", "/models"):
            await handleModels(writer)
        case ("GET", "/v1/languages"), ("GET", "/languages"):
            await handleLanguages(request, writer)
        case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
            await handleChat(request, writer)
        case ("POST", "/v1/translate"), ("POST", "/translate"):
            await handleSimpleTranslate(request, writer)
        default:
            await fail(writer, status: 404, code: "not_found",
                       message: "Unknown route: \(request.method) \(request.path)")
        }
    }

    // MARK: - GET

    private func handleHealth(_ writer: any ResponseWriter) async {
        let body = HealthResponse(
            model: config.modelName,
            server: "apple-translate-api/\(Version.string)",
            uptime_seconds: Int(Date().timeIntervalSince(startedAt)),
            default_source: config.defaultSource,
            default_target: config.defaultTarget,
            smart_skip: config.smartSkip,
            source_mode: config.sourceMode.rawValue
        )
        await writer.send(.json(200, body))
    }

    private func handleModels(_ writer: any ResponseWriter) async {
        let body = ModelList(data: [
            .init(id: config.modelName, created: Int(startedAt.timeIntervalSince1970), owned_by: "apple")
        ])
        await writer.send(.json(200, body))
    }

    private func handleLanguages(_ request: HTTPRequest, _ writer: any ResponseWriter) async {
        let supported = await engine.systemSupportedLanguages()
        var pairStatus: String?
        if let source = request.query["source"], let target = request.query["target"] {
            pairStatus = await engine.pairStatus(source: source, target: target)
        }
        let body = LanguagesResponse(
            catalog: LanguageCatalog.all.map { .init(id: $0.id, english: $0.english, chinese: $0.chinese) },
            system_supported: supported,
            default_target: config.defaultTarget,
            pair_status: pairStatus
        )
        await writer.send(.json(200, body))
    }

    // MARK: - POST /v1/chat/completions

    private func handleChat(_ request: HTTPRequest, _ writer: any ResponseWriter) async {
        let started = Date()
        guard let decoded = try? JSONDecoder().decode(ChatCompletionRequest.self, from: request.body) else {
            await fail(writer, status: 400, code: "invalid_request",
                       message: "Body is not a valid Chat Completions payload.")
            return
        }

        let messages = decoded.messages ?? []
        let instructions = messages
            .filter { $0.role == "system" || $0.role == "developer" }
            .map(\.content.plainText)
        let userTexts = messages
            .filter { $0.role == "user" }
            .map(\.content.plainText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var target = decoded.explicitTarget
        let payload: String
        if let direct = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines), !direct.isEmpty {
            payload = direct
        } else if let last = userTexts.last {
            let analysis = PromptParser.analyze(last)
            payload = analysis.payload
            if target == nil { target = analysis.targetLanguage }
        } else if let lastSystem = instructions.last?.trimmingCharacters(in: .whitespacesAndNewlines), !lastSystem.isEmpty {
            payload = lastSystem
        } else {
            await fail(writer, status: 400, code: "empty_input",
                       message: "No text to translate: send a user message or a `text` field.")
            return
        }

        if target == nil, !instructions.isEmpty {
            target = PromptParser.targetLanguage(in: instructions.joined(separator: "\n"))
        }
        let resolvedTarget = target ?? config.defaultTarget

        guard payload.count <= config.maxCharacters else {
            await fail(writer, status: 413, code: "input_too_long",
                       message: "Text is \(payload.count) characters; the limit is \(config.maxCharacters). "
                              + "Raise it with AT_MAX_CHARS if you need to.")
            return
        }

        do {
            let outcome = try await engine.translate(
                text: payload,
                source: decoded.explicitSource,
                target: resolvedTarget
            )
            if config.logRequests {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Log.info("chat \(outcome.sourceLanguage)->\(outcome.targetLanguage) "
                         + "\(payload.count)字->\(outcome.text.count)字 \(ms)ms"
                         + (outcome.skipped ? " (already target language)" : ""))
            }
            if decoded.stream == true {
                await streamResponse(outcome, writer: writer)
            } else {
                await writer.send(.json(200, completionResponse(outcome, promptCharacters: payload.count)))
            }
        } catch let failure as TranslationFailure {
            if config.logRequests { Log.error("chat failed: \(failure.code) — \(failure.message)") }
            await fail(writer, status: failure.status, code: failure.code, message: failure.message)
        } catch {
            await fail(writer, status: 500, code: "internal_error", message: "\(error)")
        }
    }

    private func completionResponse(_ outcome: TranslationOutcome, promptCharacters: Int) -> ChatCompletionResponse {
        let promptTokens = estimateTokens(promptCharacters)
        let completionTokens = estimateTokens(outcome.text.count)
        return ChatCompletionResponse(
            id: Self.completionID(),
            created: Int(Date().timeIntervalSince1970),
            model: config.modelName,
            choices: [.init(message: .init(content: outcome.text))],
            usage: .init(
                prompt_tokens: promptTokens,
                completion_tokens: completionTokens,
                total_tokens: promptTokens + completionTokens
            )
        )
    }

    private func streamResponse(_ outcome: TranslationOutcome, writer: any ResponseWriter) async {
        let id = Self.completionID()
        let created = Int(Date().timeIntervalSince1970)
        let model = config.modelName

        await writer.beginStream(
            status: 200,
            contentType: "text/event-stream; charset=utf-8",
            extraHeaders: [
                "X-Translation-Source": outcome.sourceLanguage,
                "X-Translation-Target": outcome.targetLanguage,
            ]
        )

        func emit(_ chunk: ChatCompletionChunk) async {
            guard let data = try? JSONEncoder().encode(chunk),
                  let json = String(data: data, encoding: .utf8) else { return }
            await writer.write("data: \(json)\n\n")
        }

        await emit(ChatCompletionChunk(
            id: id, created: created, model: model,
            choices: [.init(delta: .init(role: "assistant", content: nil), finish_reason: nil)]
        ))
        for piece in Self.chunks(of: outcome.text) {
            await emit(ChatCompletionChunk(
                id: id, created: created, model: model,
                choices: [.init(delta: .init(role: nil, content: piece), finish_reason: nil)]
            ))
        }
        await emit(ChatCompletionChunk(
            id: id, created: created, model: model,
            choices: [.init(delta: .init(role: nil, content: nil), finish_reason: "stop")]
        ))
        await writer.write("data: [DONE]\n\n")
        await writer.endStream()
    }

    // MARK: - POST /v1/translate

    private func handleSimpleTranslate(_ request: HTTPRequest, _ writer: any ResponseWriter) async {
        guard let decoded = try? JSONDecoder().decode(SimpleTranslateRequest.self, from: request.body),
              let payload = decoded.payload else {
            await fail(writer, status: 400, code: "invalid_request",
                       message: #"Send {"text": "...", "target": "zh-Hans"}."#)
            return
        }
        guard payload.count <= config.maxCharacters else {
            await fail(writer, status: 413, code: "input_too_long",
                       message: "Text is \(payload.count) characters; the limit is \(config.maxCharacters).")
            return
        }
        do {
            let outcome = try await engine.translate(
                text: payload,
                source: decoded.explicitSource,
                target: decoded.explicitTarget ?? config.defaultTarget
            )
            await writer.send(.json(200, SimpleTranslateResponse(
                translation: outcome.text,
                source_language: outcome.sourceLanguage,
                target_language: outcome.targetLanguage,
                skipped: outcome.skipped
            )))
        } catch let failure as TranslationFailure {
            await fail(writer, status: failure.status, code: failure.code, message: failure.message)
        } catch {
            await fail(writer, status: 500, code: "internal_error", message: "\(error)")
        }
    }

    // MARK: - Helpers

    private func fail(_ writer: any ResponseWriter, status: Int, code: String, message: String) async {
        await writer.send(.json(status, APIErrorEnvelope.make(message, code: code)))
    }

    /// 只用来给客户端一个非零的 usage，不是真实分词结果。
    private func estimateTokens(_ characters: Int) -> Int {
        max(1, Int((Double(characters) / 4.0).rounded(.up)))
    }

    private static func completionID() -> String {
        "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// 把结果切成语义上还算完整的片段，让 SSE 看起来像在流式输出。
    static func chunks(of text: String, limit: Int = 40) -> [String] {
        guard text.count > limit else { return [text] }
        let breakCharacters: Set<Character> = ["。", "！", "？", "；", "，", ".", "!", "?", ";", ",", "\n", " "]
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= limit, breakCharacters.contains(character) {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
