import Foundation
import Testing
@testable import TetherCore

/// Screen shapes from Claude Code 2.1.308 (screenshots, 2026-10-30).
@Suite struct PromptSuggestionTests {
    let rule = String(repeating: "\u{2500}", count: 60)

    func screen(_ prompt: String) -> String {
        [
            "\u{25CF} Both agents finished.",
            "",
            "\u{273B} Crunched for 35s \u{00B7} done 9:17 PM",
            "",
            rule,
            prompt,
            rule,
            "  Opus 5.5   Tether  claude/macos-ios-app-plan-qngk9x",
            "  \u{25B8}\u{25B8} auto mode on (shift+tab to cycle)",
        ].joined(separator: "\n")
    }

    @Test func readsTheSuggestionInThePromptBox() {
        #expect(PromptSuggestion.extract(viewport: screen("\u{276F} are they done yet?")) == "are they done yet?")
        #expect(PromptSuggestion.extract(viewport: screen("\u{276F}\u{00A0}delete the bench test files  ")) == "delete the bench test files")
    }

    @Test func emptyBoxHasNoSuggestion() {
        #expect(PromptSuggestion.extract(viewport: screen("\u{276F} ")) == nil)
        #expect(PromptSuggestion.extract(viewport: screen("\u{276F}")) == nil)
    }

    @Test func aPastPromptOutsideABoxIsIgnored() {
        let text = ["\u{276F} say hi", "", "\u{25CF} Hi.", ""].joined(separator: "\n")
        #expect(PromptSuggestion.extract(viewport: text) == nil)
    }

    @Test func takesTheLowestBox() {
        let text = screen("\u{276F} old") + "\n" + screen("\u{276F} new")
        #expect(PromptSuggestion.extract(viewport: text) == "new")
    }
}
