import Foundation
import MemosCore
import SwiftProtobuf

nonisolated enum MemoDate {
    /// “Today, 8:12 AM”, “Yesterday, 9:05 PM”, “Mon, 10:02 PM”, then “Oct 14” and “Oct 14, 2025”.
    static func timeline(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return String(localized: "Today, \(time)", comment: "A memo's date on the timeline; the time is formatted, like 8:12 AM.") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday, \(time)", comment: "A memo's date on the timeline; the time is formatted, like 9:05 PM.") }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            let weekday = date.formatted(.dateTime.weekday(.abbreviated))
            return String(localized: "\(weekday), \(time)", comment: "A memo's date on the timeline in the past week: an abbreviated weekday and a time, like “Mon, 10:02 PM”.")
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// “2h”, “3d”, as in a comment's header.
    static func short(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "now", comment: "A comment's age when under a minute old.")
        case ..<3600: return String(localized: "\(Int(seconds / 60))m", comment: "A comment's age in minutes, abbreviated.")
        case ..<86_400: return String(localized: "\(Int(seconds / 3600))h", comment: "A comment's age in hours, abbreviated.")
        case ..<(7 * 86_400): return String(localized: "\(Int(seconds / 86_400))d", comment: "A comment's age in days, abbreviated.")
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

nonisolated extension Memo {
    /// The memo's first line of real text, for search rows, widgets and Spotlight.
    var previewText: String {
        let document = MarkdownDocument(parsing: content)
        for block in document.blocks {
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text):
                return text
            case .list(let items):
                return items.map(\.text).joined(separator: " · ")
            default:
                continue
            }
        }
        return content
    }

    /// The memo as plain text on one line: no list markers, checkboxes or emphasis marks.
    var plainText: String {
        var parts: [String] = []
        for block in MarkdownDocument(parsing: content).blocks {
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text): parts.append(text)
            case .list(let items): parts.append(contentsOf: items.map(\.text))
            case .code(_, let code): parts.append(code)
            case .table(let header, let rows): parts.append((header + rows.flatMap(\.self)).joined(separator: " "))
            case .rule: break
            }
        }
        return parts.map { part in
            // Keeps an escaped # from turning into a tag when the text is rendered again.
            let inline = try? AttributedString(markdown: InlineMarkdown.markingEscapedHashes(part), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return inline.map { String($0.characters) } ?? part
        }
        .joined(separator: " ")
        .replacingOccurrences(of: "\n", with: " ")
    }

    /// The title shown in navigation and Spotlight.
    var displayTitle: String {
        let title = property.title
        if !title.isEmpty { return title }
        let line = previewText.split(separator: "\n").first.map(String.init) ?? ""
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    var audioAttachment: Attachment? {
        attachments.first { $0.type.hasPrefix("audio/") }
    }
}
