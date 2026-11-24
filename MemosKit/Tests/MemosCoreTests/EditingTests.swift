import Foundation
import Testing
@testable import MemosCore

/// `marked` with the selection shown by `|`: one for a cursor, two around a selection.
private func unmark(_ marked: String) -> (text: String, selection: NSRange) {
    let parts = marked.components(separatedBy: "|")
    precondition(parts.count == 2 || parts.count == 3, "mark a cursor or a selection")
    let start = parts[0].utf16.count
    let length = parts.count == 3 ? parts[1].utf16.count : 0
    return (parts.joined(), NSRange(location: start, length: length))
}

private func mark(_ text: String, _ selection: NSRange) -> String {
    let ns = text as NSString
    let before = ns.substring(to: selection.location)
    let after = ns.substring(from: NSMaxRange(selection))
    if selection.length == 0 { return before + "|" + after }
    return before + "|" + ns.substring(with: selection) + "|" + after
}

private func apply(_ edit: TextEdit?, to text: String) -> String? {
    edit.map { mark($0.applied(to: text), $0.selection) }
}

private func format(_ format: MarkdownFormat, _ marked: String) -> String {
    let (text, selection) = unmark(marked)
    return apply(MarkdownEditing.edit(format, in: text, selection: selection), to: text)!
}

private func returnKey(_ marked: String) -> String? {
    let (text, selection) = unmark(marked)
    return apply(MarkdownEditing.continueList(in: text, selection: selection), to: text)
}

@Suite struct `Return in a list` {
    @Test(arguments: [
        ("- milk|", "- milk\n- |"),
        ("* milk|", "* milk\n* |"),
        ("1. one|", "1. one\n2. |"),
        ("9) nine|", "9) nine\n10) |"),
        ("- [x] done|", "- [x] done\n- [ ] |"),
        ("- [ ] todo|", "- [ ] todo\n- [ ] |"),
        ("> quoted|", "> quoted\n> |"),
        ("> - quoted item|", "> - quoted item\n> - |"),
        ("  - nested|", "  - nested\n  - |"),
        ("- mi|lk", "- mi\n- |lk"),
        ("- |one| two", "- \n- | two"),
    ])
    func `continues the item's marker`(before: String, after: String) {
        #expect(returnKey(before) == after)
    }

    @Test(arguments: [
        ("- milk\n- |", "- milk\n|"),
        ("- [ ] |", "|"),
        ("3. |", "|"),
        ("> - |", "> |"),
        ("> |", "|"),
        ("- |  ", "|  "),
    ])
    func `an empty item ends the list`(before: String, after: String) {
        #expect(returnKey(before) == after)
    }

    @Test(arguments: [
        "plain|",
        "# Title|",
        "|- milk",
        "```\n- code|",
        "~~~swift\n> code|",
        "$$\n- math|",
    ])
    func `other lines and code blocks get a plain line break`(before: String) {
        #expect(returnKey(before) == nil)
    }

    @Test func `a closed code block doesn't stop lists after it`() {
        #expect(returnKey("```\n- a\n```\n- b|") == "```\n- a\n```\n- b\n- |")
        #expect(returnKey("    ```\n- b|") == "    ```\n- b\n- |")
    }
}

@Suite struct `Inline formatting` {
    @Test func `wraps the selection and keeps it selected`() {
        #expect(format(.bold, "say |hello| there") == "say **|hello|** there")
        #expect(format(.italic, "say |hello| there") == "say *|hello|* there")
        #expect(format(.strikethrough, "say |hello| there") == "say ~~|hello|~~ there")
        #expect(format(.code, "say |hello| there") == "say `|hello|` there")
    }

    @Test func `toggles off when already wrapped, inside or out`() {
        #expect(format(.bold, "say **|hello|** there") == "say |hello| there")
        #expect(format(.bold, "say |**hello**| there") == "say |hello| there")
        #expect(format(.code, "|`x`|") == "|x|")
    }

    @Test func `an empty selection inserts a pair, and a second tap takes it out`() {
        #expect(format(.bold, "a|") == "a**|**")
        #expect(format(.bold, "a**|**") == "a|")
    }

    @Test func `italic and bold share a character without being confused`() {
        #expect(format(.italic, "**|x|**") == "***|x|***")
        #expect(format(.italic, "|**x**|") == "*|**x**|*")
        #expect(format(.italic, "***|x|***") == "**|x|**")
        #expect(format(.bold, "***|x|***") == "*|x|*")
    }

    @Test func `leaves surrounding whitespace outside the markers`() {
        #expect(format(.bold, "|hello |world") == "**|hello|** world")
    }

    @Test func `wraps each selected line on its own, skipping list markers`() {
        #expect(format(.bold, "|one\ntwo|") == "|**one**\n**two**|")
        #expect(format(.bold, "- |one\n- two|") == "- |**one**\n- **two**|")
        #expect(format(.bold, "|**one**\n**two**|") == "|one\ntwo|")
    }
}

@Suite struct `Line formatting` {
    @Test func `adds a marker to every selected line, skipping blank ones between`() {
        #expect(format(.bulletList, "|one\n\ntwo|") == "- |one\n\n- two|")
        #expect(format(.numberedList, "|a\nb|") == "1. |a\n2. b|")
        #expect(format(.quote, "|a\nb|") == "> |a\n> b|")
        #expect(format(.bulletList, "|") == "- |")
    }

    @Test func `takes the marker off when every line has it`() {
        #expect(format(.bulletList, "- |one\n- two|") == "|one\ntwo|")
        #expect(format(.quote, "> - a|") == "- a|")
        #expect(format(.taskList, "- [x] |milk") == "|milk")
    }

    @Test func `switches between kinds of marker`() {
        #expect(format(.taskList, "- |milk") == "- [ ] |milk")
        #expect(format(.taskList, "* milk|") == "* [ ] milk|")
        #expect(format(.bulletList, "- [ ] milk|") == "- milk|")
        #expect(format(.numberedList, "- one|") == "1. one|")
        #expect(format(.bulletList, "|- a\nb|") == "- |a\n- b|")
        #expect(format(.taskList, "|- [x] a\nb|") == "- [x] |a\n- [ ] b|")
    }

    @Test func `headings replace each other and toggle off`() {
        #expect(format(.heading1, "|Title") == "# |Title")
        #expect(format(.heading2, "# Title|") == "## Title|")
        #expect(format(.heading1, "# Title|") == "Title|")
        #expect(format(.heading3, "- item|") == "### item|")
    }

    @Test func `keeps indentation and quotes around list markers`() {
        #expect(format(.bulletList, "  one|") == "  - one|")
        #expect(format(.bulletList, "> one|") == "> - one|")
    }

    @Test func `a cursor inside the old marker ends up after the new one`() {
        #expect(format(.numberedList, "-| one") == "1. |one")
    }
}

@Suite struct `Links and code blocks` {
    @Test func `link puts the cursor where the missing part goes`() {
        #expect(format(.link, "|") == "[|]()")
        #expect(format(.link, "see |Memos|") == "see [Memos](|)")
        #expect(format(.link, "|https://usememos.com|") == "[|](https://usememos.com)")
        #expect(format(.link, "|[Memos](https://usememos.com)|") == "|Memos|")
    }

    @Test func `code block fences the selected lines and comes off again`() {
        #expect(format(.codeBlock, "|") == "```\n|\n```")
        #expect(format(.codeBlock, "|let x = 1|") == "```\n|let x = 1|\n```")
        #expect(format(.codeBlock, "a = |1") == "```\na = |1\n```")
        #expect(format(.codeBlock, "|```\nlet x = 1\n```|") == "|let x = 1|")
    }
}

@Suite struct `Tag completion` {
    private func token(_ marked: String) -> TagToken? {
        let (text, selection) = unmark(marked)
        return MarkdownEditing.tagToken(in: text, at: selection.location)
    }

    @Test func `finds the tag being typed`() {
        #expect(token("Notes #wo|") == TagToken(range: NSRange(location: 6, length: 3), prefix: "wo"))
        #expect(token("#wo|rk") == TagToken(range: NSRange(location: 0, length: 5), prefix: "wo"))
        #expect(token("a #|") == TagToken(range: NSRange(location: 2, length: 1), prefix: ""))
        #expect(token("#work/|") == TagToken(range: NSRange(location: 0, length: 6), prefix: "work/"))
        #expect(token("#work/me|") == TagToken(range: NSRange(location: 0, length: 8), prefix: "work/me"))
        #expect(token("one\n#读|书") == TagToken(range: NSRange(location: 4, length: 3), prefix: "读"))
    }

    @Test(arguments: [
        "a#|",
        "#tag |",
        "`#co|`",
        "```\n#tag|",
        "$$\n#tag|",
        "$$\n#|",
        "$$\na #x|\n\nb\n$$",
        "$$\na #|\n\nb\n$$",
        "$$ #meta|",
        "$$\na\n    $$\n#still|",
        "$a +\n#x|$",
        "$a +\n#|$",
        "\\#|",
        "|#tag",
        "##|",
    ])
    func `ignores what isn't a tag`(marked: String) {
        #expect(token(marked) == nil)
    }

    @Test func `still finds tags outside display math and four-space fences`() {
        #expect(token("$$\na\n\nb\n$$\n#wo|") == TagToken(range: NSRange(location: 11, length: 3), prefix: "wo"))
        #expect(token("    $$\n#wo|") == TagToken(range: NSRange(location: 7, length: 3), prefix: "wo"))
        #expect(token("```\n$$\n```\n#wo|") == TagToken(range: NSRange(location: 11, length: 3), prefix: "wo"))
    }

    @Test func `completing replaces the whole token and adds one space`() {
        let complete = { (marked: String, tag: String) -> String in
            let (text, selection) = unmark(marked)
            let token = MarkdownEditing.tagToken(in: text, at: selection.location)!
            return apply(MarkdownEditing.completeTag(tag, replacing: token, in: text), to: text)!
        }
        #expect(complete("#wo|", "work") == "#work |")
        #expect(complete("#wo|rk next", "work/meeting") == "#work/meeting |next")
        #expect(complete("a #|\nb", "reading") == "a #reading |\nb")
    }

    @Test func `suggests tags by prefix, nested ones included, most used first`() {
        let tags = ["work", "reading", "work/meeting", "home/workshop", "Wonder"]
        #expect(MarkdownEditing.tagSuggestions(for: "wo", in: tags) == ["work", "work/meeting", "Wonder", "home/workshop"])
        #expect(MarkdownEditing.tagSuggestions(for: "work/", in: tags) == ["work/meeting"])
        #expect(MarkdownEditing.tagSuggestions(for: "meet", in: tags) == ["work/meeting"])
        #expect(MarkdownEditing.tagSuggestions(for: "", in: tags, limit: 2) == ["work", "reading"])
        #expect(MarkdownEditing.tagSuggestions(for: "zzz", in: tags).isEmpty)
    }

    @Test func `the tag button starts a tag after a space when needed`() {
        let insert = { (marked: String) -> String in
            let (text, selection) = unmark(marked)
            return apply(MarkdownEditing.insertTagMarker(in: text, selection: selection), to: text)!
        }
        #expect(insert("|") == "#|")
        #expect(insert("word|") == "word #|")
        #expect(insert("word |") == "word #|")
        #expect(insert("(|") == "(#|")
        #expect(insert("buy |milk|") == "buy #milk|")
    }
}
