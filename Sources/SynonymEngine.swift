import Foundation

struct SynonymChange: Identifiable, Equatable {
    let id: Int
    let original: String
    let replacement: String
}

struct SynonymResult: Equatable {
    let text: String
    let changes: [SynonymChange]
    let wordCount: Int
    let requestedCount: Int
    let eligibleCount: Int

    static let empty = SynonymResult(text: "", changes: [], wordCount: 0, requestedCount: 0, eligibleCount: 0)
    var actualPercentage: Double { wordCount == 0 ? 0 : Double(changes.count) / Double(wordCount) * 100 }
}

enum SynonymEngine {
    // Deliberately small, one-word English substitutions. Avoid ambiguous common
    // words such as "right", "light", "mean", "fine", and "significant".
    private static let alternatives: [String: [String]] = [
        "approximately": ["roughly"],
        "frequently": ["often"], "often": ["frequently"],
        "occasionally": ["sometimes"], "sometimes": ["occasionally"],
        "nevertheless": ["nonetheless"], "nonetheless": ["nevertheless"],
        "primarily": ["mainly", "chiefly"], "mainly": ["primarily", "chiefly"], "chiefly": ["mainly", "primarily"],
        "usually": ["typically"], "typically": ["usually"],
        "rapidly": ["quickly", "swiftly"], "quickly": ["rapidly", "swiftly"], "swiftly": ["quickly", "rapidly"],
        "entirely": ["completely", "wholly"], "completely": ["entirely", "wholly"], "wholly": ["entirely", "completely"],
        "nearly": ["almost"], "almost": ["nearly"],
        "especially": ["particularly"], "particularly": ["especially"],
        "certainly": ["definitely"], "definitely": ["certainly"],
        "perhaps": ["maybe"], "maybe": ["perhaps"],
        "seldom": ["rarely"], "rarely": ["seldom"],
        "previously": ["earlier"],
        "subsequently": ["afterward"],
        "unexpectedly": ["surprisingly"],
        "enormous": ["immense"], "immense": ["enormous"],
        "tiny": ["minuscule"], "minuscule": ["tiny"],
        "numerous": ["many"],
        "obvious": ["evident"], "evident": ["obvious"],
        "difficult": ["challenging"],
        "additional": ["extra"],
        "inexpensive": ["affordable"],
        "assistance": ["help"],
        "happiness": ["joy"],
        "sadness": ["sorrow"],
        "courage": ["bravery"], "bravery": ["courage"],
        "gratitude": ["thankfulness"], "thankfulness": ["gratitude"],
        "honesty": ["truthfulness"], "truthfulness": ["honesty"]
    ]

    private static let words = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+(?:['’_\-][\p{L}\p{M}\p{N}]+)*"#)
    private static let protectedPatterns = [
        #"(?s)```.*?(?:```|\z)|`[^`\r\n]*`"#,
        #"(?i)\b(?:[a-z][a-z0-9+.\-]*://|www\.)[^\s<>]+"#,
        #"[\p{L}\p{N}.!#$%&'*+/=?^_`{|}~\-]+@[\p{L}\p{N}.\-]+\.[\p{L}]{2,}"#,
        #"(?<!\S)(?:/|~/|[a-zA-Z]:\\)\S+"#
    ].map { try! NSRegularExpression(pattern: $0) }

    private struct Candidate {
        let range: NSRange
        let original: String
        let replacement: String
        let rank: UInt64
    }

    static func rewrite(_ text: String, percentage: Double, seed: UInt64) -> SynonymResult {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = words.matches(in: text, range: fullRange)
        let fraction = percentage.isFinite ? max(0, min(100, percentage)) / 100 : 0
        let requested = Int((Double(matches.count) * fraction).rounded())
        guard requested > 0 else {
            return SynonymResult(text: text, changes: [], wordCount: matches.count, requestedCount: 0, eligibleCount: 0)
        }
        let protected = protectedPatterns.flatMap { $0.matches(in: text, range: fullRange).map(\.range) }
            .sorted { $0.location < $1.location }
        var protectedIndex = 0
        var candidates: [Candidate] = []
        for match in matches {
            while protectedIndex < protected.count && NSMaxRange(protected[protectedIndex]) <= match.range.location {
                protectedIndex += 1
            }
            if protectedIndex < protected.count && NSIntersectionRange(protected[protectedIndex], match.range).length > 0 { continue }
            let original = source.substring(with: match.range)
            let lowercase = original.lowercased()
            guard let choices = alternatives[lowercase],
                  original == lowercase || original == original.uppercased() || original == lowercase.capitalized else { continue }
            // Mid-sentence capitalized words can be names. Sentence-initial words
            // and all-capital text are supported; mixed-case identifiers are skipped.
            if original != lowercase && original != original.uppercased() && !isSentenceStart(source, before: match.range.location) { continue }
            let rank = hash(seed ^ UInt64(match.range.location))
            let chosen = choices[Int(hash(rank) % UInt64(choices.count))]
            let replacement = original == original.uppercased() ? chosen.uppercased() : original == lowercase.capitalized ? chosen.capitalized : chosen
            candidates.append(Candidate(range: match.range, original: original, replacement: replacement, rank: rank))
        }
        let selected = candidates.sorted { $0.rank == $1.rank ? $0.range.location < $1.range.location : $0.rank < $1.rank }
            .prefix(requested).sorted { $0.range.location < $1.range.location }
        let output = NSMutableString(string: text)
        for candidate in selected.reversed() { output.replaceCharacters(in: candidate.range, with: candidate.replacement) }
        let changes = selected.map { SynonymChange(id: $0.range.location, original: $0.original, replacement: $0.replacement) }
        return SynonymResult(text: output as String, changes: changes, wordCount: matches.count, requestedCount: requested, eligibleCount: candidates.count)
    }

    private static func isSentenceStart(_ source: NSString, before offset: Int) -> Bool {
        guard offset > 0 else { return true }
        var index = offset - 1
        while index >= 0 {
            let unit = source.character(at: index)
            if unit == 10 || unit == 13 { return true }
            if let scalar = UnicodeScalar(unit), CharacterSet.whitespaces.contains(scalar) { index -= 1; continue }
            return [UInt16(46), 33, 63].contains(unit)
        }
        return true
    }

    private static func hash(_ value: UInt64) -> UInt64 {
        var value = value &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
