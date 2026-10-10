import Foundation

// MARK: - 请求

struct ChatMessage: Decodable, Sendable {
    let role: String
    let content: MessageContent
}

enum MessageContent: Decodable, Sendable {
    case text(String)
    case parts([Part])

    struct Part: Decodable, Sendable {
        let type: String?
        let text: String?
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .text("")
            return
        }
        if let value = try? container.decode(String.self) {
            self = .text(value)
            return
        }
        if let value = try? container.decode([Part].self) {
            self = .parts(value)
            return
        }
        self = .text("")
    }

    var plainText: String {
        switch self {
        case .text(let value): value
        case .parts(let parts): parts.compactMap(\.text).joined(separator: "\n")
        }
    }
}

/// OpenAI Chat Completions 请求里本服务用得到的字段。
/// `target_language` / `source_language`（以及几个别名）不是 OpenAI 标准字段，
/// 是本服务加的逃生舱：客户端明确指定语言对时，就不用靠猜 prompt。
struct ChatCompletionRequest: Decodable, Sendable {
    var model: String?
    var messages: [ChatMessage]?
    var stream: Bool?
    /// 直接给正文的简化用法，等价于一条 user 消息。
    var text: String?
    var target_language: String?
    var target_lang: String?
    var to: String?
    var source_language: String?
    var from: String?

    var explicitTarget: String? {
        for candidate in [target_language, target_lang, to] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty { return candidate }
        }
        return nil
    }

    var explicitSource: String? {
        for candidate in [source_language, from] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty { return candidate }
        }
        return nil
    }
}

// MARK: - 响应

struct ChatCompletionResponse: Encodable {
    let id: String
    let object = "chat.completion"
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage

    struct Choice: Encodable {
        let index = 0
        let message: ResponseMessage
        let finish_reason = "stop"
    }

    struct ResponseMessage: Encodable {
        let role = "assistant"
        let content: String
    }

    struct Usage: Encodable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }
}

struct ChatCompletionChunk: Encodable {
    let id: String
    let object = "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [Choice]

    struct Choice: Encodable {
        let index = 0
        let delta: Delta
        let finish_reason: String?
    }

    struct Delta: Encodable {
        let role: String?
        let content: String?
    }
}

struct ModelList: Encodable {
    let object = "list"
    let data: [Model]

    struct Model: Encodable {
        let id: String
        let object = "model"
        let created: Int
        let owned_by: String
    }
}

struct APIErrorEnvelope: Encodable {
    let error: Body

    struct Body: Encodable {
        let message: String
        let type: String
        let param: String?
        let code: String
    }

    static func make(_ message: String, code: String, type: String = "invalid_request_error") -> APIErrorEnvelope {
        APIErrorEnvelope(error: Body(message: message, type: type, param: nil, code: code))
    }
}
