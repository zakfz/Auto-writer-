import Foundation

enum LineBreakMode: String, CaseIterable {
    case soft = "Shift + Return"
    case returnKey = "Return"
}

enum WritingToken: Equatable {
    case text([UInt16])
    case lineBreak
    case tab
    case backspace
}

enum WritingAction: Equatable {
    case write(WritingToken)
    case mistype(WritingToken)
    case backspace

    var token: WritingToken {
        switch self {
        case .write(let token), .mistype(let token): return token
        case .backspace: return .backspace
        }
    }
}

enum TypoCorrection { case erase, replace }

enum NearbyKeyTypo {
    // QWERTY neighbors; only single ASCII letters are changed. Unicode stays intact.
    private static let neighbors: [UInt16: String] = [
        97: "sqwz", 98: "vghn", 99: "xdfv", 100: "sfercx", 101: "wrsd",
        102: "dgrtvc", 103: "fhtyvb", 104: "gjyubn", 105: "uojk", 106: "hkuinm",
        107: "jliom", 108: "kop", 109: "njk", 110: "bhjm", 111: "ipkl",
        112: "ol", 113: "wa", 114: "tefd", 115: "adwezx", 116: "ryfg",
        117: "yihj", 118: "cfgb", 119: "qeas", 120: "zsdc", 121: "tugh", 122: "asx"
    ]

    static func replacement(for token: WritingToken, choice: Double) -> WritingToken? {
        guard case .text(let units) = token, units.count == 1, let original = units.first else { return nil }
        let uppercase = (65...90).contains(original)
        let lowercase = uppercase ? original + 32 : original
        guard let choices = neighbors[lowercase] else { return nil }
        let values = Array(choices.utf16)
        let index = min(values.count - 1, Int(max(0, min(1, choice)) * Double(values.count)))
        let replacement = values[index]
        return .text([uppercase ? replacement - 32 : replacement])
    }
}

struct WritingPlan {
    let tokens: [WritingToken]

    init(text: String, expandTabs: Bool) {
        tokens = text.flatMap { character -> [WritingToken] in
            switch character {
            case "\n", "\r", "\r\n": return [.lineBreak]
            case "\t":
                return expandTabs ? Array(repeating: .text([32]), count: 4) : [.tab]
            default: return [.text(Array(String(character).utf16))]
            }
        }
    }

    static func interval(wordsPerMinute: Double, varied: Bool, randomUnit: Double) -> TimeInterval {
        let base = 60 / (max(1, wordsPerMinute) * 5)
        return varied ? base * (0.7 + min(1, max(0, randomUnit)) * 0.6) : base
    }
}

// The cursor advances only after the event sender confirms delivery.
struct WritingCursor {
    let plan: WritingPlan
    private(set) var position = 0
    private(set) var isPaused = false
    private(set) var isStopped = false
    private(set) var correction: TypoCorrection?

    var next: WritingToken? {
        guard !isPaused, !isStopped, position < plan.tokens.count else { return nil }
        return plan.tokens[position]
    }

    var isComplete: Bool { position == plan.tokens.count }
    var progress: Double { plan.tokens.isEmpty ? 0 : Double(position) / Double(plan.tokens.count) }
    func nextAction(typosEnabled: Bool, errorRate: Double, chance: Double, neighborChoice: Double) -> WritingAction? {
        guard let token = next else { return nil }
        if correction == .erase { return .backspace }
        if correction == .replace { return .write(token) }
        if typosEnabled, chance < max(0, min(1, errorRate)),
           let replacement = NearbyKeyTypo.replacement(for: token, choice: neighborChoice) {
            return .mistype(replacement)
        }
        return .write(token)
    }

    mutating func delivered(_ action: WritingAction) {
        guard let token = next else { return }
        switch (correction, action) {
        case (nil, .mistype): correction = .erase
        case (.erase, .backspace): correction = .replace
        case (nil, .write(let value)), (.replace, .write(let value)):
            guard value == token else { return }
            position += 1
            correction = nil
        default: break
        }
    }
    mutating func delivered() {
        if let token = next, correction == nil { delivered(.write(token)) }
    }
    mutating func pause() { isPaused = true }
    mutating func resume() { if !isStopped { isPaused = false } }
    mutating func stop() { isStopped = true }
}
