import Foundation

struct NoteContext: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case application
        case url
        case file

        var title: String {
            switch self {
            case .application:
                return "Apps"
            case .url:
                return "Web"
            case .file:
                return "Files"
            }
        }

        var sortOrder: Int {
            switch self {
            case .application:
                return 0
            case .url:
                return 1
            case .file:
                return 2
            }
        }
    }

    let kind: Kind
    let identifier: String
    let displayName: String
    let secondaryLabel: String?
    let navigationTarget: String?
    let sourceBundleIdentifier: String?
    let sourceRootPath: String?
    let fileSystemIdentifier: String?
    let fileBookmarkData: Data?

    init(
        kind: Kind,
        identifier: String,
        displayName: String,
        secondaryLabel: String?,
        navigationTarget: String?,
        sourceBundleIdentifier: String? = nil,
        sourceRootPath: String? = nil,
        fileSystemIdentifier: String? = nil,
        fileBookmarkData: Data? = nil
    ) {
        self.kind = kind
        self.identifier = identifier
        self.displayName = displayName
        self.secondaryLabel = secondaryLabel
        self.navigationTarget = navigationTarget
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceRootPath = sourceRootPath
        self.fileSystemIdentifier = fileSystemIdentifier
        self.fileBookmarkData = fileBookmarkData
    }

    var id: String {
        if kind == .file, let fileSystemIdentifier, !fileSystemIdentifier.isEmpty {
            return "\(kind.rawValue)::\(fileSystemIdentifier)"
        }

        return "\(kind.rawValue)::\(identifier)"
    }
}
