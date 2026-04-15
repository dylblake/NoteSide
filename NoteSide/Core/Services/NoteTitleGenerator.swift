import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class NoteTitleGenerator {

    static let minimumBodyLength = 20

    func generateTitle(body: String, context: NoteContext) async -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

        #if canImport(FoundationModels)
        if let aiTitle = await generateWithFoundationModels(
            body: trimmed.isEmpty ? nil : String(trimmed.prefix(500)),
            context: context
        ) {
            return aiTitle
        }
        #endif

        guard trimmed.count >= Self.minimumBodyLength else { return nil }
        return generateWithNaturalLanguage(body: trimmed)
    }

    // MARK: - Tier 1: Foundation Models (macOS 26+)

    #if canImport(FoundationModels)
    private func generateWithFoundationModels(body: String?, context: NoteContext) async -> String? {
        guard #available(macOS 26, *) else { return nil }

        do {
            let session = LanguageModelSession()
            let contextLabel = context.secondaryLabel ?? context.displayName
            let prompt: String
            if let body, !body.isEmpty {
                prompt = "Generate a concise title (max 6 words) for this note. Context: \(contextLabel). Note: \(body). Reply with only the title, no quotes or punctuation."
            } else {
                prompt = "Generate a concise title (max 6 words) for a note being taken on: \(contextLabel). Reply with only the title, no quotes or punctuation."
            }

            let response = try await session.respond(to: prompt)
            let title = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        } catch {
            return nil
        }
    }
    #endif

    // MARK: - Tier 2: NaturalLanguage keyword extraction

    private func generateWithNaturalLanguage(body: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = body

        var keywords: [String] = []
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        tagger.enumerateTags(
            in: body.startIndex..<body.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, tokenRange in
            if let tag, tag == .personalName || tag == .placeName || tag == .organizationName {
                keywords.append(String(body[tokenRange]))
            }
            return true
        }

        tagger.enumerateTags(
            in: body.startIndex..<body.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: options
        ) { tag, tokenRange in
            if let tag, tag == .noun {
                let word = String(body[tokenRange])
                if !keywords.contains(word) {
                    keywords.append(word)
                }
            }
            return true
        }

        if keywords.count >= 2 {
            return keywords.prefix(4)
                .map { $0.capitalized }
                .joined(separator: " ")
        }

        // Fallback: use first ~30 characters trimmed to a word boundary
        let prefix = String(body.prefix(30))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[prefix.startIndex..<lastSpace])
        }
        return prefix
    }
}
