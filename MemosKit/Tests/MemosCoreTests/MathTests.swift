import Foundation
import Testing
@testable import MemosCore

@Suite struct Math {
    private func math(_ text: String) -> [String] {
        InlineSpans.scan(text).filter { $0.kind == .math }.map { String(text[$0.range]) }
    }

    @Test func `inline math follows the server's dollar rules`() {
        #expect(math("Euler: $e^{i\\pi} + 1 = 0$.") == ["$e^{i\\pi} + 1 = 0$"])
        #expect(math("$a$ and $$b$$") == ["$a$", "$$b$$"])
        #expect(math("$20,000 #budget and $30,000") == [], "a dollar before a digit doesn't close")
        #expect(math("cost $5 and $10") == [])
        #expect(math("text $ #plain") == [])
        #expect(math("$ x$ and $x $") == [], "no space inside a single dollar")
        #expect(math("$#one$$ #two$ #plain") == ["$#one$$ #two$"], "only a run of the same length closes")
        #expect(math("$$#math$ #plain") == [], "a run doesn't reopen part-way through")
        #expect(math("\\$$#math$ #plain") == ["$#math$"], "a run can open after an escaped dollar")
        #expect(math("\\$5 and 6$") == [])
        #expect(math("$a\nb$") == ["$a\nb$"], "math continues across lines")
        #expect(math("$a\n\nb$") == [], "but not across a blank line")
        #expect(math("`$x$` and $`y`$") == ["$`y`$"], "whichever opens first wins")
        #expect(math("``$x$`` and $y$") == ["$y$"], "a code span closes on a run of the same length")
        #expect(math("[link](https://x.com/$a$) and $b$") == ["$b$"], "a link destination is never math")
        #expect(math("[link](https://x.com/a(b)/$c$) and $d$") == ["$d$"], "parentheses in a destination balance")
        #expect(math("interval ]0,1](with $x$ excluded)") == ["$x$"], "a `](` without a `[` isn't a link")
        #expect(math(#"[link](https://x.com/a\)/$c$) and $d$"#) == ["$d$"], "an escaped parenthesis doesn't end a destination")
        #expect(math("interval [0,1](with $x$ excluded)") == ["$x$"], "a space ends the URL, so this isn't a link")
        #expect(math(#"[link](https://x.com/$a$ "title") and $b$"#) == ["$b$"], "a title may follow the URL")
    }

    @Test func `tags inside math aren't tags`() {
        #expect(ContentAnalysis("$#math$ #plain").tags == ["plain"])
        #expect(ContentAnalysis("$20,000 #budget and $30,000").tags == ["budget"])
        #expect(ContentAnalysis("$#one$$ #two$ #plain").tags == ["plain"])
        #expect(ContentAnalysis("$$#math$ #plain").tags == ["math", "plain"])
        #expect(ContentAnalysis("\\$$#math$ #plain").tags == ["plain"])
        #expect(ContentAnalysis("$$\n#math\n$$\n\n#plain").tags == ["plain"])
        #expect(ContentAnalysis("$$meta\n#math").tags == [], "an unclosed fence runs to the end")
        #expect(ContentAnalysis("$$meta$x\n#plain").tags == ["plain"], "a dollar after the fence makes it text")
        #expect(ContentAnalysis("```text\n$$\n```\n\n#plain").tags == ["plain"])
        #expect(ContentAnalysis("costs $5 #food\n\nnot a$ #tag").tags == ["food", "tag"], "math stays in its block")
        #expect(!ContentAnalysis("$`x`$").hasCode)
    }

    @Test func `display math is a block`() {
        let document = MarkdownDocument(parsing: """
        Before
        $$
        \\begin{matrix} a & b \\\\ c & d \\end{matrix}
        $$
        After $$x$$
        $$$ info
        y
        $$
        $$$
        """)
        #expect(document.blocks == [
            .paragraph("Before"),
            .math("\\begin{matrix} a & b \\\\ c & d \\end{matrix}"),
            .paragraph("After $$x$$"),
            .math("y\n$$"),
        ])
    }

    @Test func `fences indented four spaces or a tab don't open or close blocks`() {
        #expect(MarkdownDocument(parsing: "   $$\nx\n   $$").blocks == [.math("x")])
        #expect(MarkdownDocument(parsing: "    $$\nx\n    $$").blocks == [.paragraph("    $$\nx\n    $$")])
        #expect(MarkdownDocument(parsing: "\t$$\nx\n\t$$").blocks == [.paragraph("\t$$\nx\n\t$$")])
        #expect(MarkdownDocument(parsing: "  \t$$\nx\n  \t$$").blocks == [.paragraph("  \t$$\nx\n  \t$$")])
        #expect(MarkdownDocument(parsing: "$$\nx\n    $$\ny\n$$").blocks == [.math("x\n    $$\ny")])
        #expect(MarkdownDocument(parsing: "$$\nx\n\t$$\ny\n$$").blocks == [.math("x\n\t$$\ny")])
        #expect(ContentAnalysis("    $$\n#plain").tags == ["plain"])

        #expect(MarkdownDocument(parsing: "   ```swift\nlet x = 1\n   ```").blocks == [.code(language: "swift", code: "let x = 1")])
        #expect(MarkdownDocument(parsing: "    ```\ncode\n    ```").blocks == [.paragraph("    ```\ncode\n    ```")])
        #expect(MarkdownDocument(parsing: "\t```\ncode\n\t```").blocks == [.paragraph("\t```\ncode\n\t```")])
        #expect(MarkdownDocument(parsing: "```\ncode\n    ```\nmore\n```").blocks == [.code(language: nil, code: "code\n    ```\nmore")])
        #expect(MarkdownDocument(parsing: "```\ncode\n\t```\nmore\n```").blocks == [.code(language: nil, code: "code\n\t```\nmore")])
        #expect(MarkdownDocument(parsing: "````\n```\n````").blocks == [.code(language: nil, code: "```")])
    }

    @Test func `editor tag spans exclude display math and fenced code`() {
        func editorTags(_ text: String) -> [String] {
            TagScanner.matches(in: text, excluding: TagScanner.literalSpans(in: text)).map(\.tag)
        }
        #expect(editorTags("$$\na #x\n\nb\n$$") == [], "display math with a blank line")
        #expect(editorTags("$$\n#tag") == [], "unclosed display math")
        #expect(editorTags("$$ #meta\nx\n$$") == [], "text on the opening fence")
        #expect(editorTags("$$\na\n\nb\n$$\n#real\n$$\nc\n$$") == ["real"], "closing fence doesn't pair with the next opening fence")
        #expect(editorTags("```\n#code\n```\n#real") == ["real"])
        #expect(editorTags("```text\n$$\n```\n#real") == ["real"])
        #expect(editorTags("$$\n```\n$$\n#real") == ["real"])
        #expect(editorTags("    $$\n#real") == ["real"], "four-space fence doesn't open math")
        #expect(editorTags("$$\na\n    $$\n#still") == [], "four-space fence doesn't close math")
        #expect(editorTags("$a +\n#x$") == [], "multi-line inline math")
    }

    @Test func `inline Markdown keeps math as written`() {
        let parsed = InlineParsing.attributed("*see* $a*b*c$ and $\\{x\\}$ or **$x_1$**")
        #expect(String(parsed.characters) == "see $a*b*c$ and $\\{x\\}$ or $x_1$")
        for tex in ["$a*b*c$", "$\\{x\\}$", "$x_1$"] {
            let range = try! #require(parsed.range(of: tex))
            #expect(parsed[range].runs.allSatisfy { $0.inlinePresentationIntent?.contains(.code) == true })
        }
        #expect(parsed.runs[InlineMathAttribute.self].compactMap(\.0) == ["a*b*c", "\\{x\\}", "x_1"], "each run carries its TeX")
        #expect(InlineParsing.attributed("$$x$$").runs[InlineMathAttribute.self].compactMap(\.0) == ["x"])
        let bold = try! #require(parsed.range(of: "$x_1$"))
        #expect(parsed[bold].runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true, "emphasis around math still applies")
        #expect(String(InlineParsing.attributed("cost $5 and *$10*").characters) == "cost $5 and $10")
        let link = InlineParsing.attributed("[link](https://x.com/$a$)")
        #expect(link.runs.first?.link == URL(string: "https://x.com/$a$"), "a URL keeps its dollars")
        #expect(String(InlineParsing.attributed(##"Unit \#13 $\#x$"##).characters) == "Unit #\u{2060}13 $\\#x$")
    }

    @Test func `math inside a link stays tappable source rather than a typeset image`() throws {
        let url = URL(string: "https://example.com")!

        let formulaOnly = InlineParsing.attributed("[$x^2$](https://example.com)")
        #expect(String(formulaOnly.characters) == "$x^2$")
        #expect(formulaOnly.runs.allSatisfy { $0.link == url })
        #expect(formulaOnly.runs[InlineMathAttribute.self].compactMap(\.0).isEmpty)

        let mixed = InlineParsing.attributed("[see $a*b*c$](https://example.com) and $y$")
        #expect(String(mixed.characters) == "see $a*b*c$ and $y$")
        let linkedRange = try #require(mixed.range(of: "see $a*b*c$"))
        #expect(mixed[linkedRange].runs.allSatisfy { $0.link == url })
        #expect(mixed.runs[InlineMathAttribute.self].compactMap(\.0) == ["y"], "unlinked math on the same line still typesets")
    }
}
