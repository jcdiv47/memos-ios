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

    @Test func `inline Markdown keeps math as written`() {
        let parsed = InlineParsing.attributed("*see* $a*b*c$ and $\\{x\\}$ or **$x_1$**")
        #expect(String(parsed.characters) == "see $a*b*c$ and $\\{x\\}$ or $x_1$")
        for tex in ["$a*b*c$", "$\\{x\\}$", "$x_1$"] {
            let range = try! #require(parsed.range(of: tex))
            #expect(parsed[range].runs.allSatisfy { $0.inlinePresentationIntent?.contains(.code) == true })
        }
        let bold = try! #require(parsed.range(of: "$x_1$"))
        #expect(parsed[bold].runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true, "emphasis around math still applies")
        #expect(String(InlineParsing.attributed("cost $5 and *$10*").characters) == "cost $5 and $10")
        #expect(String(InlineParsing.attributed(##"Unit \#13 $\#x$"##).characters) == "Unit #\u{2060}13 $\\#x$")
    }
}
