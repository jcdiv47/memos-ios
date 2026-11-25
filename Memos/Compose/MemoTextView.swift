import MemosCore
import SwiftUI
import UIKit

/// The composer's editor. A `UITextView` rather than `TextEditor`, because formatting, list
/// continuation and tag completion have to go through UIKit's undoable edits, leave an input
/// method's marked text alone, and add key commands and an edit menu.
struct MemoTextView: UIViewRepresentable {
    let model: ComposerModel
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> EditorTextView {
        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .ink
        textView.backgroundColor = .clear
        textView.accessibilityLabel = String(localized: "Memo")
        textView.delegate = context.coordinator
        textView.text = model.text
        textView.selectedRange = model.selection
        textView.onFormat = { [weak coordinator = context.coordinator] format in coordinator?.model.format(format) }
        textView.onPasteImages = { [weak coordinator = context.coordinator] providers in
            guard let model = coordinator?.model else { return }
            Task { await model.addPastedImages(providers) }
        }
        model.editor.attach(textView) { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.textViewDidChange(textView)
        }
        context.coordinator.highlight(textView)
        return textView
    }

    func updateUIView(_ textView: EditorTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.isFocused = $isFocused
        // Text set from outside, like a transcript or a restored draft. Marked text belongs to the
        // input method until it's committed, so it's never replaced.
        if textView.markedTextRange == nil, !textView.text.utf16.elementsEqual(model.text.utf16) {
            coordinator.isUpdating = true
            textView.text = model.text
            let length = (model.text as NSString).length
            textView.selectedRange = NSRange(location: min(model.selection.location, length), length: 0)
            coordinator.isUpdating = false
            coordinator.highlight(textView)
        }
        textView.wantsFocus = isFocused
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, isFocused: $isFocused)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var model: ComposerModel
        var isFocused: Binding<Bool>
        var isUpdating = false

        private static let tagKey = NSAttributedString.Key("memosTag")

        init(model: ComposerModel, isFocused: Binding<Bool>) {
            self.model = model
            self.isFocused = isFocused
        }

        func textViewDidChange(_ textView: UITextView) {
            sync(textView, textChanged: true)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            sync(textView, textChanged: false)
        }

        private func sync(_ textView: UITextView, textChanged: Bool) {
            guard !isUpdating else { return }
            let wasComposing = model.isComposing
            let isComposing = textView.markedTextRange != nil
            model.editorDidChange(text: textView.text, selection: textView.selectedRange, isComposing: isComposing)
            // Committing marked text can change nothing but the marking.
            if !isComposing, textChanged || wasComposing { highlight(textView) }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !isFocused.wrappedValue { isFocused.wrappedValue = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if isFocused.wrappedValue { isFocused.wrappedValue = false }
        }

        /// Return continues a list, as one undoable edit with the line break.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", textView.markedTextRange == nil,
                  textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true,
                  let edit = MarkdownEditing.continueList(in: textView.text, selection: range)
            else { return true }
            return !model.editor.apply(edit)
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard textView.isEditable, textView.markedTextRange == nil else { return nil }
            let sections = MarkdownFormat.menuSections.map { formats in
                UIMenu(options: .displayInline, children: formats.map { format in
                    UIAction(title: format.title, image: UIImage(icon: format.icon)) { [weak self] _ in
                        self?.model.format(format)
                    }
                })
            }
            let menu = UIMenu(title: String(localized: "Format"), image: UIImage(icon: .type), children: sections)
            // The system's bold, italic and underline would style the text rather than write Markdown.
            let suggested = suggestedActions.filter { ($0 as? UIMenu)?.identifier != .format && ($0 as? UIMenu)?.identifier != .textStyle }
            return UIMenu(children: suggested + [menu])
        }

        /// Tags turn Memos Blue, Markdown's syntax (list and quote markers, `**`, `_`, `~~`,
        /// backticks, a link's brackets and address) recedes to Ink 3, and list items hang their
        /// wrapped lines under the text after the marker. Only colour and paragraph indents
        /// change, so the selection, the undo stack and any marked text are untouched; while an
        /// input method is composing it waits.
        func highlight(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            let text: String = textView.text
            let font = textView.font ?? .preferredFont(forTextStyle: .body)
            let styling = EditorStyling(text: text, font: font)
            if styling != applied {
                applied = styling
                let storage = textView.textStorage
                let whole = NSRange(location: 0, length: storage.length)
                storage.beginEditing()
                storage.removeAttribute(Self.tagKey, range: whole)
                storage.removeAttribute(.paragraphStyle, range: whole)
                storage.addAttribute(.foregroundColor, value: UIColor.ink, range: whole)
                for range in styling.syntax {
                    storage.addAttribute(.foregroundColor, value: UIColor.ink3, range: range)
                }
                for range in styling.tags {
                    storage.addAttributes([.foregroundColor: UIColor.memosBlue, Self.tagKey: true], range: range)
                }
                for indent in styling.indents {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.headIndent = indent.width
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: indent.range)
                }
                storage.endEditing()
            }
            textView.typingAttributes[.foregroundColor] = UIColor.ink
            textView.typingAttributes[Self.tagKey] = nil
        }

        /// What the text was last styled with, so a keystroke that moves nothing restyles nothing.
        private var applied: EditorStyling?
    }
}

/// Where the editor's colours and indents go, worked out from the text alone.
struct EditorStyling: Equatable {
    struct Indent: Equatable {
        /// The whole paragraph.
        var range: NSRange
        /// How far wrapped lines start in: the width of the indent and marker.
        var width: CGFloat
    }

    var tags: [NSRange] = []
    var syntax: [NSRange] = []
    var indents: [Indent] = []

    init(text: String, font: UIFont) {
        let string = text as NSString
        let whole = NSRange(location: 0, length: string.length)
        tags = TagScanner.matches(in: text, excluding: TagScanner.literalSpans(in: text)).map { NSRange($0.range, in: text) }

        // Block markers at the start of a line: a list item, a task, a quote, a heading's #s.
        Self.blockMarker.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match else { return }
            let leading = match.range(at: 1)
            let marker = match.range(at: 2)
            syntax.append(marker)
            // Headings don't wrap under their #s; lists and quotes hang.
            guard string.character(at: marker.location) != UInt16(UInt8(ascii: "#")) else { return }
            let prefix = string.substring(with: NSRange(location: leading.location, length: NSMaxRange(marker) - leading.location))
            let width = (prefix as NSString).size(withAttributes: [.font: font]).width
            indents.append(Indent(range: string.paragraphRange(for: marker), width: width.rounded(.up)))
        }

        // Inline code first: what's inside it is literal, so nothing in it counts as syntax.
        var code: [NSRange] = []
        Self.codeSpan.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match else { return }
            code.append(match.range)
            syntax += Self.delimiters(of: match)
        }
        func isInCode(_ range: NSRange) -> Bool {
            code.contains { NSIntersectionRange($0, range).length > 0 }
        }
        for pattern in [Self.strong, Self.strike, Self.emphasis] {
            pattern.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let match, !isInCode(match.range) else { return }
                syntax += Self.delimiters(of: match)
            }
        }
        Self.link.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match, !isInCode(match.range) else { return }
            // The opening bracket, then the closing bracket and the address.
            syntax.append(NSRange(location: match.range.location, length: 1))
            let address = match.range(at: 1)
            syntax.append(NSRange(location: address.location - 1, length: address.length + 1))
        }
    }

    /// A paired span's opening and closing delimiters, from its first capture group.
    private static func delimiters(of match: NSTextCheckingResult) -> [NSRange] {
        let opening = match.range(at: 1)
        return [opening, NSRange(location: NSMaxRange(match.range) - opening.length, length: opening.length)]
    }

    // The patterns are fixed, so compiling them can't fail.
    private static let blockMarker = try! NSRegularExpression(
        pattern: #"^([ \t]*)((?:[-*+] \[[ xX]\]|[-*+]|\d+[.)])[ \t]+|>[ \t]?|#{1,6}[ \t]+)"#,
        options: .anchorsMatchLines
    )
    private static let codeSpan = try! NSRegularExpression(pattern: #"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let strong = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let strike = try! NSRegularExpression(pattern: #"(~~)(?=\S)(.+?)(?<=\S)\1"#)
    private static let emphasis = try! NSRegularExpression(pattern: #"(?<![*\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*\w])"#)
    private static let link = try! NSRegularExpression(pattern: #"\[[^\]\n]+\](\([^)\n]+\))"#)
}

final class EditorTextView: UITextView {
    var onFormat: ((MarkdownFormat) -> Void)?
    /// Images pasted into the text, which become attachments rather than text.
    var onPasteImages: (([NSItemProvider]) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // A plain-text view offers no Paste for an image on its own. Checking for one doesn't
        // read the pasteboard, so it doesn't ask for permission.
        if action == #selector(paste(_:)), isEditable, onPasteImages != nil, UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Paste from the edit menu and ⌘V alike. An image copied from a web page also carries its
    /// URL; the image is what was meant.
    override func paste(_ sender: Any?) {
        let images = UIPasteboard.general.hasImages
            ? UIPasteboard.general.itemProviders.filter { provider in
                provider.registeredContentTypes.contains { $0.conforms(to: .image) }
            }
            : []
        guard isEditable, let onPasteImages, !images.isEmpty else { return super.paste(sender) }
        onPasteImages(images)
    }

    /// Focus as SwiftUI asked for it, applied once the view is in a window.
    var wantsFocus = false {
        didSet {
            guard wantsFocus != oldValue else { return }
            if wantsFocus {
                focusIfNeeded()
            } else {
                // Later, for the same reason as focusing.
                Task { @MainActor [weak self] in
                    guard let self, !self.wantsFocus, self.isFirstResponder else { return }
                    self.resignFirstResponder()
                }
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        focusIfNeeded()
    }

    private func focusIfNeeded() {
        guard wantsFocus, window != nil else { return }
        // Later: becoming first responder during a SwiftUI update re-enters it.
        Task { @MainActor [weak self] in
            guard let self, self.wantsFocus, self.window != nil, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(title: MarkdownFormat.bold.title, action: #selector(formatBold), input: "b", modifierFlags: .command),
            UIKeyCommand(title: MarkdownFormat.italic.title, action: #selector(formatItalic), input: "i", modifierFlags: .command),
            UIKeyCommand(title: MarkdownFormat.link.title, action: #selector(formatLink), input: "k", modifierFlags: .command),
        ]
        // Ahead of UIKit's own ⌘B and ⌘I, which would style the text rather than write Markdown.
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands + (super.keyCommands ?? [])
    }

    @objc private func formatBold() { format(.bold) }
    @objc private func formatItalic() { format(.italic) }
    @objc private func formatLink() { format(.link) }

    private func format(_ format: MarkdownFormat) {
        guard isEditable, markedTextRange == nil else { return }
        onFormat?(format)
    }
}

/// The composer model's handle on its text view, for edits that have to go through UIKit to be
/// undoable.
final class EditorProxy {
    private weak var textView: UITextView?
    private var didEdit: (() -> Void)?

    func attach(_ textView: UITextView, didEdit: @escaping () -> Void) {
        self.textView = textView
        self.didEdit = didEdit
    }

    var isAttached: Bool { textView != nil }

    /// The text and selection as the text view has them right now.
    var snapshot: (text: String, selection: NSRange)? {
        textView.map { ($0.text, $0.selectedRange) }
    }

    /// Applies `edit` as one undoable step. Refused while an input method is composing.
    @discardableResult
    func apply(_ edit: TextEdit) -> Bool {
        guard let textView, textView.markedTextRange == nil,
              let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
              let end = textView.position(from: start, offset: edit.range.length),
              let range = textView.textRange(from: start, to: end)
        else { return false }
        textView.replace(range, withText: edit.replacement)
        textView.selectedRange = edit.selection
        // `replace(_:withText:)` doesn't reliably tell the delegate.
        didEdit?()
        return true
    }
}

extension MarkdownFormat {
    var title: String {
        switch self {
        case .bold: String(localized: "Bold")
        case .italic: String(localized: "Italic")
        case .strikethrough: String(localized: "Strikethrough")
        case .code: String(localized: "Code")
        case .heading1: String(localized: "Heading 1")
        case .heading2: String(localized: "Heading 2")
        case .heading3: String(localized: "Heading 3")
        case .bulletList: String(localized: "Bulleted List")
        case .numberedList: String(localized: "Numbered List")
        case .taskList: String(localized: "Task")
        case .quote: String(localized: "Quote")
        case .link: String(localized: "Link")
        case .codeBlock: String(localized: "Code Block")
        }
    }

    var icon: Lucide {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .strikethrough: .strikethrough
        case .code: .code
        case .heading1: .heading1
        case .heading2: .heading2
        case .heading3: .heading3
        case .bulletList: .list
        case .numberedList: .listOrdered
        case .taskList: .listChecks
        case .quote: .textQuote
        case .link: .link
        case .codeBlock: .braces
        }
    }

    /// The Format menu, in the formatting bar and the text's edit menu alike.
    static let menuSections: [[MarkdownFormat]] = [
        [.bold, .italic, .strikethrough, .code],
        [.heading1, .heading2, .heading3],
        [.bulletList, .numberedList, .taskList, .quote],
        [.link, .codeBlock],
    ]
}
