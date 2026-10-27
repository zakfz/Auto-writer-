import Foundation

@main
struct CoreTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func main() {
        check(WritingPlan(text: "", expandTabs: true).tokens.isEmpty, "Empty input")
        check(WritingPlan(text: "A\r\nB\rC\nD", expandTabs: true).tokens == [
            .text([65]), .lineBreak, .text([66]), .lineBreak, .text([67]), .lineBreak, .text([68])
        ], "Windows and Mac line endings become one Return each")
        check(WritingPlan(text: "\t", expandTabs: true).tokens == Array(repeating: .text([32]), count: 4), "Tab expansion")
        check(WritingPlan(text: "\t", expandTabs: false).tokens == [.tab], "Literal tab")
        let multilingual = "Příliš žluťoučký kůň. 日本語 العربية 👩🏽‍💻 e\u{301}"
        let plan = WritingPlan(text: multilingual, expandTabs: true)
        let recovered = plan.tokens.reduce(into: [UInt16]()) { units, token in
            if case .text(let value) = token { units.append(contentsOf: value) }
        }
        check(String(decoding: recovered, as: UTF16.self) == multilingual, "Unicode and combining sequences round trip")
        check(plan.tokens.count == multilingual.count, "Grapheme clusters stay together")
        check(WritingPlan.interval(wordsPerMinute: 60, varied: false, randomUnit: 0) == 0.2, "WPM uses five characters per word")
        check(abs(WritingPlan.interval(wordsPerMinute: 60, varied: true, randomUnit: 0) - 0.14) < 0.00001, "Minimum rhythm interval")
        check(abs(WritingPlan.interval(wordsPerMinute: 60, varied: true, randomUnit: 1) - 0.26) < 0.00001, "Maximum rhythm interval")
        check(WritingPlan.interval(wordsPerMinute: 0, varied: false, randomUnit: 0).isFinite, "Invalid speed is bounded")

        var cursor = WritingCursor(plan: WritingPlan(text: "abc", expandTabs: true))
        check(cursor.next == .text([97]), "Starts at first token")
        cursor.delivered()
        cursor.pause()
        check(cursor.next == nil, "Pause prevents delivery")
        cursor.delivered()
        check(cursor.position == 1, "Paused delivery cannot advance")
        cursor.resume()
        check(cursor.next == .text([98]), "Resume keeps place")
        cursor.delivered()
        cursor.delivered()
        check(cursor.isComplete && cursor.next == nil && cursor.progress == 1, "Completion stops delivery")
        cursor.delivered()
        check(cursor.position == 3, "Cannot advance past end")

        var stopped = WritingCursor(plan: WritingPlan(text: "secret", expandTabs: false))
        stopped.delivered()
        stopped.stop()
        stopped.resume()
        stopped.delivered()
        check(stopped.next == nil && stopped.position == 1, "Stop cannot resume or leak more tokens")
        check(NearbyKeyTypo.replacement(for: .text([114]), choice: 0) == .text([116]), "r can become neighboring t")
        check(NearbyKeyTypo.replacement(for: .text([82]), choice: 0) == .text([84]), "Uppercase stays uppercase")
        for value in ["ě", "日本語", "👩🏽‍💻", "e\u{301}", "7", " ", "."] {
            check(NearbyKeyTypo.replacement(for: .text(Array(value.utf16)), choice: 0) == nil, "Leave Unicode and nonletters untouched")
        }
        var correction = WritingCursor(plan: WritingPlan(text: "r", expandTabs: true))
        let typo = correction.nextAction(typosEnabled: true, errorRate: 1, chance: 0, neighborChoice: 0)!
        check(typo == .mistype(.text([116])), "Plan wrong letter first")
        correction.delivered(typo)
        check(correction.position == 0 && !correction.isComplete, "Typo does not count as source progress")
        correction.pause()
        check(correction.nextAction(typosEnabled: true, errorRate: 1, chance: 0, neighborChoice: 0) == nil, "Pause blocks an unfinished correction")
        correction.resume()
        let erase = correction.nextAction(typosEnabled: true, errorRate: 1, chance: 0, neighborChoice: 0)!
        check(erase == .backspace, "Resume erases the wrong letter first")
        correction.delivered(erase)
        check(correction.position == 0, "Backspace does not advance source")
        let replace = correction.nextAction(typosEnabled: true, errorRate: 1, chance: 0, neighborChoice: 0)!
        check(replace == .write(.text([114])), "Correction cannot trigger another typo")
        correction.delivered(replace)
        check(correction.isComplete && correction.progress == 1, "Last character finishes only after correction")

        var interrupted = WritingCursor(plan: WritingPlan(text: "r", expandTabs: true))
        interrupted.delivered(typo)
        interrupted.stop()
        interrupted.resume()
        check(interrupted.nextAction(typosEnabled: true, errorRate: 1, chance: 0, neighborChoice: 0) == nil, "Stop cancels pending backspace")

        var exact = WritingCursor(plan: WritingPlan(text: "r", expandTabs: true))
        check(exact.nextAction(typosEnabled: false, errorRate: 1, chance: 0, neighborChoice: 0) == .write(.text([114])), "Disabled mode writes exact text")
        check(exact.nextAction(typosEnabled: true, errorRate: 0, chance: 0, neighborChoice: 0) == .write(.text([114])), "Zero probability produces no typo")
        exact.delivered(.backspace)
        exact.delivered(.write(.text([116])))
        check(exact.position == 0, "Unexpected actions cannot advance the source")

        let original = WritingPlan(text: "Every ASCII letter: ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz.\n\(multilingual)\t123", expandTabs: false)
        var simulation = WritingCursor(plan: original)
        var output: [WritingToken] = []
        var mistakes = 0
        var steps = 0
        while let action = simulation.nextAction(typosEnabled: true, errorRate: 1, chance: 0, neighborChoice: 0.5) {
            steps += 1
            if steps > original.tokens.count * 3 { fatalError("Correction loop did not terminate") }
            if action == .backspace { output.removeLast() }
            else { output.append(action.token) }
            if case .mistype = action { mistakes += 1 }
            simulation.delivered(action)
        }
        check(mistakes > 50, "Simulation exercises many corrections")
        check(output == original.tokens, "Even 100 percent typo frequency reconstructs exact multilingual input")
        check(simulation.isComplete, "Simulation finishes without looping")
        testSynonyms()
        print("Passed \(assertions) checks: Unicode, typing controls, typo correction, synonym percentages, protected text, and preview stability.")
    }

    static func testSynonyms() {
        let passage = String(repeating: "frequently ", count: 200)
        let twoPercent = SynonymEngine.rewrite(passage, percentage: 2, seed: 42)
        check(twoPercent.wordCount == 200, "Count all words in the passage")
        check(twoPercent.requestedCount == 4 && twoPercent.changes.count == 4, "2 percent changes exactly four of 200 words")
        check(twoPercent.actualPercentage == 2, "Report the actual percentage")
        check(twoPercent.text.split(separator: " ").filter { $0 == "often" }.count == 4, "Replace selected occurrences, not every occurrence")
        check(twoPercent.text.hasSuffix(" "), "Keep trailing whitespace")
        check(SynonymEngine.rewrite(passage, percentage: 2, seed: 42) == twoPercent, "Preview is stable for the same input and seed")
        check(SynonymEngine.rewrite(passage, percentage: 2, seed: 43).changes != twoPercent.changes, "Shuffle can select different occurrences")
        let tenPercent = SynonymEngine.rewrite(passage, percentage: 10, seed: 42)
        check(tenPercent.changes.count == 20, "Percentage is adjustable")
        check(SynonymEngine.rewrite(passage, percentage: 0, seed: 42).text == passage, "0 percent keeps the original")
        check(SynonymEngine.rewrite(passage, percentage: -10, seed: 42).text == passage, "Negative values are bounded")
        check(SynonymEngine.rewrite(passage, percentage: .nan, seed: 42).text == passage, "Invalid percentages keep the original")
        check(SynonymEngine.rewrite(passage, percentage: .infinity, seed: 42).text == passage, "Infinite percentages are safe")
        check(SynonymEngine.rewrite("", percentage: 20, seed: 42).changes.isEmpty, "Empty input has no swaps")
        check(SynonymEngine.rewrite(String(repeating: "often ", count: 24), percentage: 2, seed: 42).changes.isEmpty, "Short text rounds to zero whole words")
        check(SynonymEngine.rewrite(String(repeating: "often ", count: 25), percentage: 2, seed: 42).changes.count == 1, "Nearest whole-word count is used")

        let sparse = SynonymEngine.rewrite("quartz quartz frequently", percentage: 100, seed: 42)
        check(sparse.text == "quartz quartz often" && sparse.changes.count == 1, "Do not force replacements without suitable synonyms")
        check(sparse.requestedCount == 3 && sparse.eligibleCount == 1, "Report a shortfall accurately")
        check(SynonymEngine.rewrite("The right light is fine.", percentage: 100, seed: 42).changes.isEmpty, "Ambiguous words stay unchanged")
        let cases = SynonymEngine.rewrite("FREQUENTLY. Frequently. frequently FrEqUeNtLy", percentage: 100, seed: 42)
        check(cases.text == "OFTEN. Often. often FrEqUeNtLy", "Preserve uppercase and sentence capitalization; skip mixed case")
        check(SynonymEngine.rewrite("We met Frequently yesterday.", percentage: 100, seed: 42).changes.isEmpty, "Skip possible names in mid-sentence")
        let multilingual = "frequently,\r\n\tnevertheless!  日本語 العربية 👩🏽‍💻 e\u{301}"
        check(SynonymEngine.rewrite(multilingual, percentage: 100, seed: 42).text == "often,\r\n\tnonetheless!  日本語 العربية 👩🏽‍💻 e\u{301}", "Preserve punctuation, line endings, tabs, and Unicode")
        let protected = "```\nfrequently often\n```\n`often` https://often.example/frequently frequently@often.example /often/frequently ~/frequently.txt C:\\often\\file.txt www.often.example"
        check(SynonymEngine.rewrite(protected, percentage: 100, seed: 42).text == protected, "Preserve code, URLs, emails, and file paths")
        let identifiers = "frequently_used often-used frequently2 123.45"
        check(SynonymEngine.rewrite(identifiers, percentage: 100, seed: 42).text == identifiers, "Preserve identifiers, hyphenated terms, and numbers")
        check(SynonymEngine.rewrite("```\nfrequently", percentage: 100, seed: 42).changes.isEmpty, "Protect unfinished code fences")

        // The preview is a value, so changing settings later cannot mutate a
        // writing session that has already captured its character plan.
        var previewCursor = WritingCursor(plan: WritingPlan(text: twoPercent.text, expandTabs: true))
        _ = SynonymEngine.rewrite(passage, percentage: 20, seed: 10)
        var delivered: [UInt16] = []
        while let token = previewCursor.next {
            if case .text(let units) = token { delivered.append(contentsOf: units) }
            previewCursor.delivered()
        }
        check(String(decoding: delivered, as: UTF16.self) == twoPercent.text, "Typing uses the exact preview snapshot")
        check(passage == String(repeating: "frequently ", count: 200), "Keep original pasted text untouched")
    }
}
