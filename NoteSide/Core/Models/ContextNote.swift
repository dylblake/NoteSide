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
    }
}
