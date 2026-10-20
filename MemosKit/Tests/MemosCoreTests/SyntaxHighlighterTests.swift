import Foundation
import Testing
@testable import MemosCore

/// The highlighted pieces of `code`, as `kind: text` strings, plain text left out.
private func tokens(_ code: String, _ language: String) -> [String] {
    SyntaxHighlighter.segments(of: code, language: language).compactMap { segment in
        segment.kind.map { "\($0.rawValue): \(segment.text)" }
    }
}

private func texts(_ code: String, _ language: String, _ kind: SyntaxTokenKind) -> [String] {
    SyntaxHighlighter.segments(of: code, language: language).filter { $0.kind == kind }.map(\.text)
}

@Suite struct `Syntax highlighting` {
    @Test(arguments: [
        ("swift", "swift"), ("Swift", "swift"), ("py", "python"), ("python3", "python"), ("js", "javascript"),
        ("jsx", "javascript"), ("tsx", "typescript"), ("ts", "typescript"), ("golang", "go"), ("rs", "rust"),
        ("c++", "cpp"), ("objective-c", "objc"), ("kt", "kotlin"), ("rb", "ruby"), ("sh", "shell"), ("zsh", "shell"),
        ("bash", "shell"), ("yml", "yaml"), ("xml", "html"), ("postgres", "sql"), ("jsonc", "json"),
        ("py title=\"a.py\"", "python"), ("scss", "scss"),
    ])
    func `fence languages and their aliases`(info: String, name: String) {
        #expect(SyntaxLanguage(fenceInfo: info)?.name == name)
    }

    @Test func `unknown or missing language stays plain`() {
        #expect(SyntaxLanguage(fenceInfo: "klingon") == nil)
        #expect(SyntaxHighlighter.tokens(in: "let x = 1", language: nil).isEmpty)
        #expect(SyntaxHighlighter.tokens(in: "let x = 1", language: "klingon").isEmpty)
        #expect(SyntaxHighlighter.segments(of: "let x = 1", language: nil) == [SyntaxSegment(text: "let x = 1", kind: nil)])
    }

    @Test func swift() {
        let code = """
        @MainActor struct Box<T> { // a box
            let count = 0x1F + 2.5e-3
            /* outer /* nested */ still comment */
            #if DEBUG
            var text = "say \\"hi\\""
            let block = \"\"\"
            line "one"
            \"\"\"
            for i in 1..<5 {}
        }
        """
        let result = tokens(code, "swift")
        #expect(result.contains("attribute: @MainActor"))
        #expect(result.contains("keyword: struct"))
        #expect(result.contains("type: Box"))
        #expect(result.contains("comment: // a box"))
        #expect(result.contains("number: 0x1F"))
        #expect(result.contains("number: 2.5e-3"))
        #expect(result.contains("comment: /* outer /* nested */ still comment */"))
        #expect(result.contains("attribute: #if"))
        #expect(result.contains(#"string: "say \"hi\"""#))
        #expect(result.contains("string: \"\"\"\n    line \"one\"\n    \"\"\""))
        #expect(texts(code, "swift", .number).contains("1") && texts(code, "swift", .number).contains("5"), "a range isn't one number")
        #expect(texts(code, "swift", .punctuation).contains("..<"))
    }

    @Test func python() {
        let code = """
        @dataclass
        def greet(name: str) -> None:  # say hi
            '''Docs
            span lines'''
            return f"Hi {name}" if True else rb'\\x00'
        """
        let result = tokens(code, "python")
        #expect(result.contains("attribute: @dataclass"))
        #expect(result.contains("keyword: def"))
        #expect(result.contains("type: str"))
        #expect(result.contains("keyword: None"))
        #expect(result.contains("comment: # say hi"))
        #expect(result.contains("string: '''Docs\n    span lines'''"))
        #expect(result.contains("string: f\"Hi {name}\""))
        #expect(result.contains("string: rb'\\x00'"))
    }

    @Test func `javascript and typescript`() {
        let code = "const $el = `multi\nline ${x}` // done\ninterface Props { name: string }"
        let js = tokens(code, "js")
        #expect(js.contains("keyword: const"))
        #expect(js.contains("string: `multi\nline ${x}`"))
        #expect(js.contains("comment: // done"))
        #expect(!js.contains("keyword: interface"))
        let ts = tokens(code, "tsx")
        #expect(ts.contains("keyword: interface"))
        #expect(ts.contains("type: Props"))
        #expect(ts.contains("type: string"))
    }

    @Test func json() {
        let result = tokens(#"{"name": "Memos", "stars": 1.5e3, "ok": true, "none": null}"#, "json")
        #expect(result.contains(#"property: "name""#))
        #expect(result.contains(#"string: "Memos""#))
        #expect(result.contains("number: 1.5e3"))
        #expect(result.contains("keyword: true"))
        #expect(result.contains("keyword: null"))
    }

    @Test func `go, rust and c`() {
        let go = tokens("func main() {\n\tfmt.Println(`raw\n\\n`) // hi\n}", "go")
        #expect(go.contains("keyword: func"))
        #expect(go.contains("string: `raw\n\\n`"))
        #expect(!go.contains("type: Println"), "exported names aren't types in Go")

        let rust = tokens("#[derive(Debug)]\nfn first<'a>(s: &'a str) -> char { println!(\"{}\", 'x'); 'x' }", "rust")
        #expect(rust.contains("attribute: #[derive(Debug)]"))
        #expect(rust.contains("attribute: 'a"))
        #expect(rust.contains("type: str"))
        #expect(rust.contains("attribute: println!"))
        #expect(rust.contains("string: 'x'"))

        let c = tokens("#include <stdio.h>\nint main(void) { printf(\"%d\\n\", 42); }", "c")
        #expect(c.contains("attribute: #include"))
        #expect(c.contains("string: <stdio.h>"))
        #expect(c.contains("keyword: int"))
        #expect(c.contains("number: 42"))
    }

    @Test func `java, kotlin and ruby`() {
        let java = tokens("@Override public String toString() { return \"x\"; }", "java")
        #expect(java.contains("attribute: @Override"))
        #expect(java.contains("keyword: public"))
        #expect(java.contains("type: String"))

        let kotlin = tokens("data class User(val name: String)", "kt")
        #expect(kotlin.contains("keyword: data") && kotlin.contains("keyword: val") && kotlin.contains("type: User"))

        let ruby = tokens("class Dog # woof\n  def bark = puts(:loud, @name, \"Hi \\\"x\\\"\")\nend", "ruby")
        #expect(ruby.contains("keyword: class"))
        #expect(ruby.contains("comment: # woof"))
        #expect(ruby.contains("attribute: :loud"))
        #expect(ruby.contains("variable: @name"))
        #expect(ruby.contains("string: \"Hi \\\"x\\\"\""))
    }

    @Test func shell() {
        let code = """
        # deploy
        if [ "$#" -gt 0 ]; then echo "${HOME}/a#b" 'no \\escape' $1; fi # done
        """
        let result = tokens(code, "bash")
        #expect(result.first == "comment: # deploy")
        #expect(result.contains("keyword: if"))
        #expect(result.contains(#"string: "$#""#))
        #expect(result.contains(#"string: "${HOME}/a#b""#))
        #expect(result.contains("string: 'no \\escape'"))
        #expect(result.contains("variable: $1"))
        #expect(result.last == "comment: # done")
    }

    @Test func sql() {
        let result = tokens("SELECT \"id\", count(*) FROM memos -- all\nWHERE name = 'it''s' AND n > 3;", "sql")
        #expect(result.contains("keyword: SELECT"))
        #expect(result.contains("keyword: FROM"))
        #expect(result.contains(#"property: "id""#))
        #expect(result.contains("type: count"))
        #expect(result.contains("comment: -- all"))
        #expect(result.contains("number: 3"))
    }

    @Test func yaml() {
        let code = """
        # config
        name: "Memos"   # quoted
        port: 5230
        debug: true
        tags: [a, b]
        anchor: &base
        script: |
          echo "not: a key"
          done
        items:
          - name: one
        """
        let result = tokens(code, "yaml")
        #expect(result.contains("comment: # config"))
        #expect(result.contains("property: name"))
        #expect(result.contains(#"string: "Memos""#))
        #expect(result.contains("comment: # quoted"))
        #expect(result.contains("number: 5230"))
        #expect(result.contains("keyword: true"))
        #expect(result.contains("variable: &base"))
        #expect(result.contains("string: echo \"not: a key\""))
        #expect(result.contains("string: done"))
        #expect(result.contains("property: items"))
        #expect(texts(code, "yaml", .property).filter { $0 == "name" }.count == 2)
    }

    @Test func markup() {
        let code = """
        <!-- note -->
        <div class="card" hidden>Tom &amp; Jerry<br/></div>
        <script>const x = "<b>";</script>
        """
        let result = tokens(code, "html")
        #expect(result.contains("comment: <!-- note -->"))
        #expect(result.contains("tag: div"))
        #expect(result.contains("property: class"))
        #expect(result.contains(#"string: "card""#))
        #expect(result.contains("property: hidden"))
        #expect(result.contains("attribute: &amp;"))
        #expect(result.contains("tag: br"))
        #expect(result.contains("keyword: const"), "a script is coloured as JavaScript")
        #expect(result.contains(#"string: "<b>""#))
        #expect(texts(code, "html", .tag) == ["div", "br", "div", "script", "script"])
    }

    @Test func css() {
        let code = "/* c */\n.card > a:hover, #main { color: #fff; margin: -4px 1.5em !important; --gap: 2px }\n@media (max-width: 600px) {}"
        let result = tokens(code, "css")
        #expect(result.contains("comment: /* c */"))
        #expect(result.contains("attribute: .card"))
        #expect(result.contains("tag: a"))
        #expect(result.contains("keyword: hover"))
        #expect(result.contains("attribute: #main"))
        #expect(result.contains("property: color"))
        #expect(result.contains("number: #fff"))
        #expect(result.contains("number: 4px"))
        #expect(result.contains("number: 1.5em"))
        #expect(result.contains("keyword: !important"))
        #expect(result.contains("property: --gap"))
        #expect(result.contains("keyword: @media"))
        #expect(result.contains("property: max-width"))
    }

    @Test(arguments: ["swift", "python", "js", "json", "go", "rust", "c", "ruby", "sh", "sql", "yaml", "html", "css"])
    func `segments always add up to the code`(language: String) {
        let code = """
        "unterminated 日本語 /* never closed
        <a b='c   # 🧑‍💻 ${x} @y :z 'q\\'
        key: |
          déjà vu \u{301}
        """
        let segments = SyntaxHighlighter.segments(of: code, language: language)
        #expect(segments.map(\.text).joined() == code)
        #expect(!segments.contains { $0.text.isEmpty })
        for token in SyntaxHighlighter.tokens(in: code, language: language) {
            #expect(!token.range.isEmpty && token.range.upperBound <= code.utf8.count)
        }
    }

    @Test func `huge input is skipped and pathological input stays fast`() {
        let huge = String(repeating: "let x = 1\n", count: SyntaxHighlighter.maximumLength / 10 + 1)
        #expect(SyntaxHighlighter.tokens(in: huge, language: "swift").isEmpty)
        #expect(SyntaxHighlighter.segments(of: huge, language: "swift").map(\.text).joined() == huge)

        // Just under the limit, made of openers that never close.
        let length = SyntaxHighlighter.maximumLength - 16
        let clock = ContinuousClock()
        for (language, unit) in [("swift", "/*\"\"\"\\"), ("html", "<a b=\"<!--"), ("yaml", "- [&a "), ("css", "a:#{\"")] {
            let code = String(repeating: unit, count: length / unit.utf8.count)
            let elapsed = clock.measure { _ = SyntaxHighlighter.tokens(in: code, language: language) }
            #expect(elapsed < .seconds(1), "\(language) took \(elapsed)")
        }
    }
}
