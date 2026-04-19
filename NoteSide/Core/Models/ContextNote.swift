import Foundation

struct ContextNote: Codable, Identifiable, Hashable {
    let id: UUID
    let context: NoteContext
    let body: String
    let richTextData: Data?
    let createdAt: Date
    let updatedAt: Date
    let isPinned: Bool
    let title: String?
    let tags: [String]

    init(
        id: UUID,
        context: NoteContext,
        body: String,
        richTextData: Data?,
        createdAt: Date,
        updatedAt: Date,
        isPinned: Bool = false,
        title: String? = nil
    ) {
        self.id = id
        self.context = context
        self.body = body
        self.richTextData = richTextData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.title = title
        self.tags = Self.extractTags(from: body)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case context
        case body
        case richTextData
        case createdAt
        case updatedAt
        case isPinned
        case title
    }

    private static let tagRegex = try! NSRegularExpression(pattern: #"(?:^|\s)#(\w+)"#)

    private static func extractTags(from body: String) -> [String] {
        let nsBody = body as NSString
        let matches = tagRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
        var seen = Set<String>()
        var result: [String] = []
        for match in matches {
            let tag = nsBody.substring(with: match.range(at: 1)).lowercased()
            if seen.insert(tag).inserted {
                result.append(tag)
            }
        }
        return result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        context = try container.decode(NoteContext.self, forKey: .context)
        body = try container.decode(String.self, forKey: .body)
        richTextData = try container.decodeIfPresent(Data.self, forKey: .richTextData)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        title = try container.decodeIfPresent(String.self, forKey: .title)
        tags = Self.extractTags(from: body)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(context, forKey: .context)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(richTextData, forKey: .richTextData)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(title, forKey: .title)
    }
}
