import Foundation

/// Provider-neutral conversation model.
///
/// The transcript is append-only: once a message is appended, its bytes never change. Every vendor's
/// prompt cache is a prefix match, so rewriting history (re-rendering an old tool result, moving a
/// timestamp, re-summarizing a turn in place) silently turns every later request into a cold miss.
/// Compaction therefore never edits messages; it starts a new *epoch* (see `Compaction.swift`).
public enum Role: String, Codable, Sendable {
    case user
    case assistant
}

/// Opaque, provider-specific data that must be echoed back verbatim to the same provider family:
/// Anthropic thinking signatures, OpenAI encrypted reasoning items, Gemini `thoughtSignature`s,
/// DeepSeek/GLM `reasoning_content`. Dropping these costs quality and, on several vendors, cache hits.
public struct ProviderEcho: Codable, Equatable, Sendable {
    public var family: ProviderFamily
    public var model: String
    public var payload: JSON

    public init(family: ProviderFamily, model: String, payload: JSON) {
        self.family = family
        self.model = model
        self.payload = payload
    }
}

public struct ThinkingBlock: Codable, Equatable, Sendable {
    public var text: String
    public var echo: ProviderEcho?

    public init(text: String, echo: ProviderEcho? = nil) {
        self.text = text
        self.echo = echo
    }
}

public struct ToolUse: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var input: JSON
    public var echo: ProviderEcho?

    public init(id: String, name: String, input: JSON, echo: ProviderEcho? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.echo = echo
    }
}

public struct ToolResult: Codable, Equatable, Sendable {
    public var toolUseId: String
    public var content: String
    public var isError: Bool
    public var images: [ImageBlock]

    public init(toolUseId: String, content: String, isError: Bool = false, images: [ImageBlock] = []) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
        self.images = images
    }
}

public struct ImageBlock: Codable, Equatable, Sendable {
    public var mediaType: String
    public var base64: String

    public init(mediaType: String, base64: String) {
        self.mediaType = mediaType
        self.base64 = base64
    }
}

public enum ContentBlock: Codable, Equatable, Sendable {
    case text(String)
    case thinking(ThinkingBlock)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    case image(ImageBlock)
    /// An opaque item that only the producing provider understands (e.g. an OpenAI Responses
    /// `reasoning` item with `encrypted_content`). Other providers skip it.
    case opaque(ProviderEcho)

    private enum CodingKeys: String, CodingKey { case type, text, thinking, toolUse, toolResult, image, opaque }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "thinking": self = .thinking(try c.decode(ThinkingBlock.self, forKey: .thinking))
        case "tool_use": self = .toolUse(try c.decode(ToolUse.self, forKey: .toolUse))
        case "tool_result": self = .toolResult(try c.decode(ToolResult.self, forKey: .toolResult))
        case "image": self = .image(try c.decode(ImageBlock.self, forKey: .image))
        case "opaque": self = .opaque(try c.decode(ProviderEcho.self, forKey: .opaque))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown block \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t): try c.encode("text", forKey: .type); try c.encode(t, forKey: .text)
        case .thinking(let t): try c.encode("thinking", forKey: .type); try c.encode(t, forKey: .thinking)
        case .toolUse(let t): try c.encode("tool_use", forKey: .type); try c.encode(t, forKey: .toolUse)
        case .toolResult(let t): try c.encode("tool_result", forKey: .type); try c.encode(t, forKey: .toolResult)
        case .image(let t): try c.encode("image", forKey: .type); try c.encode(t, forKey: .image)
        case .opaque(let t): try c.encode("opaque", forKey: .type); try c.encode(t, forKey: .opaque)
        }
    }

    public var text: String? { if case .text(let t) = self { return t }; return nil }
    public var toolUse: ToolUse? { if case .toolUse(let t) = self { return t }; return nil }
    public var toolResult: ToolResult? { if case .toolResult(let t) = self { return t }; return nil }
}

public struct Message: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var role: Role
    public var blocks: [ContentBlock]

    public init(id: String = UUID().uuidString, role: Role, blocks: [ContentBlock]) {
        self.id = id
        self.role = role
        self.blocks = blocks
    }

    public static func user(_ text: String) -> Message { Message(role: .user, blocks: [.text(text)]) }
    public static func assistant(_ text: String) -> Message { Message(role: .assistant, blocks: [.text(text)]) }

    public var plainText: String { blocks.compactMap(\.text).joined(separator: "\n") }
    public var toolUses: [ToolUse] { blocks.compactMap(\.toolUse) }
}

/// A tool as offered to the model. `inputSchema` is serialized canonically.
public struct ToolSpec: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSON

    public init(name: String, description: String, inputSchema: JSON) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}
