import Testing
import TetherProtocol

@Suite struct MarkdownBlocksTests {
    @Test func headingsTablesAndParagraphs() {
        let md = """
        ### TetherCore

        | File | Role |
        |---|---|
        | ProjectStore (actor) | Persists `state.json` |
        | Layout | RemoteHost |

        That's the core.
        """
        #expect(MarkdownBlocks.parse(md) == [
            .heading(level: 3, text: "TetherCore"),
            .table(header: ["File", "Role"], rows: [["ProjectStore (actor)", "Persists `state.json`"],
                                                     ["Layout", "RemoteHost"]]),
            .paragraph("That's the core."),
        ])
    }

    @Test func listsAndNesting() {
        let md = """
        - **Package:** two libraries
          - nested
        1. first
        2) second
        """
        #expect(MarkdownBlocks.parse(md) == [
            .listItem(depth: 0, ordinal: nil, text: "**Package:** two libraries"),
            .listItem(depth: 1, ordinal: nil, text: "nested"),
            .listItem(depth: 0, ordinal: "1.", text: "first"),
            .listItem(depth: 0, ordinal: "2)", text: "second"),
        ])
    }

    @Test func fencedCodeKeepsContentVerbatim() {
        let md = "Run:\n```bash\nmake test\n# not a heading\n```\nDone."
        #expect(MarkdownBlocks.parse(md) == [
            .paragraph("Run:"),
            .code(language: "bash", text: "make test\n# not a heading"),
            .paragraph("Done."),
        ])
    }

    @Test func unterminatedFenceRunsToEnd() {
        #expect(MarkdownBlocks.parse("```\nstreaming…") == [.code(language: nil, text: "streaming…")])
    }

    @Test func rulesQuotesAndNonHeadings() {
        #expect(MarkdownBlocks.parse("---\n> quoted\n> more\n#hashtag") == [
            .rule, .quote("quoted\nmore"), .paragraph("#hashtag"),
        ])
    }

    @Test func pipeWithoutSeparatorIsAParagraph() {
        #expect(MarkdownBlocks.parse("| not a table") == [.paragraph("| not a table")])
    }
}
