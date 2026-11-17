import Foundation
import Testing
@testable import MemosCore

private let now = Date(timeIntervalSince1970: 1_792_400_000) // 2026-10-19

private func facts(
    content: String = "",
    creator: String = "users/you",
    created: Date = now,
    pinned: Bool = false,
    visibility: String = "PRIVATE",
    space: String? = nil,
    tasks: (list: Bool, open: Bool) = (false, false),
    location: Bool = false
) -> MemoFacts {
    let analysis = ContentAnalysis(content)
    return MemoFacts(
        content: content, creator: creator, createdAt: created, updatedAt: created, pinned: pinned,
        tags: analysis.tags, visibility: visibility, space: space,
        hasTaskList: tasks.list || analysis.hasTaskList, hasLink: analysis.hasLink, hasCode: analysis.hasCode,
        hasIncompleteTasks: tasks.open || analysis.hasIncompleteTasks, hasLocation: location
    )
}

private func matches(_ filter: String, _ facts: MemoFacts) throws -> Bool {
    try MemoFilter(filter).matches(facts, now: now)
}

@Suite struct `Memo filters` {
    @Test func `content contains is case-insensitive, like the server's LIKE`() throws {
        #expect(try matches(#"content.contains("kiln")"#, facts(content: "The Kiln is free")))
        #expect(try !matches(#"content.contains("glaze")"#, facts(content: "The Kiln is free")))
    }

    @Test func `tag in a list matches any tag, including ancestors of nested tags`() throws {
        let memo = facts(content: "Notes #work/ios and #reading")
        #expect(try matches(#"tag in ["work"]"#, memo))
        #expect(try matches(#"tag in ["reading", "nope"]"#, memo))
        #expect(try matches(#"tag in ["work"] && tag in ["reading"]"#, memo))
        #expect(try !matches(#"tag in ["Work"]"#, memo))
        #expect(try matches(#""work/ios" in tags"#, memo))
    }

    @Test func `the design's saved views`() throws {
        let idea = facts(content: "Idea: a commonplace book #idea", pinned: true)
        #expect(try matches(#"tag in ["idea"] && pinned"#, idea))
        #expect(try !matches(#"tag in ["idea"] && pinned"#, facts(content: "#idea")))
        #expect(try matches("has_incomplete_tasks", facts(content: "- [ ] Write the changelog")))
        #expect(try !matches("has_incomplete_tasks", facts(content: "- [x] Done")))
    }

    @Test(arguments: [
        (#"visibility == "PRIVATE""#, true),
        (#"visibility == "PUBLIC""#, false),
        (#"space == "spaces/studio""#, true),
        (#"space == null"#, false),
        (#"creator == "users/you""#, true),
        (#"creator != "users/you""#, false),
        ("has_location", true),
        ("!has_location", false),
        ("pinned == false", true),
    ])
    func `scalar fields`(filter: String, expected: Bool) throws {
        let memo = facts(visibility: "PRIVATE", space: "spaces/studio", location: true)
        #expect(try matches(filter, memo) == expected)
    }

    @Test func `a memo in no Space compares equal to null`() throws {
        #expect(try matches("space == null", facts()))
        #expect(try !matches(#"space == "spaces/studio""#, facts()))
    }

    @Test func `relative and absolute times`() throws {
        let threeDaysAgo = facts(created: now.addingTimeInterval(-3 * 86_400))
        #expect(try matches(#"created_ts > now - duration("168h")"#, threeDaysAgo))
        #expect(try !matches(#"created_ts > now - duration("24h")"#, threeDaysAgo))
        #expect(try matches(#"created_ts >= timestamp("2026-10-01T00:00:00Z")"#, threeDaysAgo))
        #expect(try matches("created_ts > timestamp(1700000000)", threeDaysAgo))
        #expect(try matches(#"updated_ts >= timestamp("2026-10-16T01:33:19.5Z")"#, facts()))
    }

    @Test func `on this day uses UTC date parts`() throws {
        let lastYear = facts(created: Calendar(identifier: .gregorian).date(byAdding: .year, value: -1, to: now)!)
        #expect(try matches("created_ts.getMonth() == now.getMonth() && created_ts.getDate() == now.getDate() && created_ts.getFullYear() < now.getFullYear()", lastYear))
    }

    @Test func `comprehensions and set functions over tags`() throws {
        let memo = facts(content: "#book/fiction #quote")
        #expect(try matches(#"tags.exists(t, t.startsWith("book"))"#, memo))
        #expect(try !matches(#"tags.all(t, t.startsWith("book"))"#, memo))
        #expect(try matches(#"tags.exists_one(t, t == "quote")"#, memo))
        #expect(try matches(#"sets.contains(tags, ["quote", "book"])"#, memo))
        #expect(try matches(#"sets.intersects(tags, ["nope", "quote"])"#, memo))
        #expect(try matches("size(tags) == 3", memo))
    }

    @Test func `boolean structure and precedence`() throws {
        let memo = facts(content: "kiln #studio", pinned: true)
        #expect(try matches(#"!pinned || content.contains("kiln") && tag in ["studio"]"#, memo))
        #expect(try !matches(#"(!pinned || content.contains("kiln")) && tag in ["nope"]"#, memo))
        #expect(try matches(#"content.matches("^k.ln")"#, memo))
    }

    @Test func `fields only the server knows are reported, not guessed`() {
        #expect(throws: CELError.self) { try matches("creator_id == 1", facts()) }
        #expect(throws: CELError.self) { try MemoFilter(#"content.contains("unterminated)"#) }
    }

    @Test func `Go durations`() {
        #expect(Evaluator.parseDuration("168h") == 604_800)
        #expect(Evaluator.parseDuration("1h30m") == 5_400)
        #expect(Evaluator.parseDuration("1.5s") == 1.5)
        #expect(Evaluator.parseDuration("250ms") == 0.25)
        #expect(Evaluator.parseDuration("-2m") == -120)
        #expect(Evaluator.parseDuration("tomorrow") == nil)
    }
}

@Suite struct `Search field` {
    @Test func `each part of the field becomes the clause in the design's table`() {
        #expect(SearchQuery(text: "kiln").filter() == #"content.contains("kiln")"#)
        #expect(SearchQuery(tokens: [.tag("reading")]).filter() == #"tag in ["reading"]"#)
        #expect(SearchToken.openTasks.filterClause == "has_incomplete_tasks")
        #expect(SearchToken.tasks.filterClause == "has_task_list")
        #expect(SearchToken.links.filterClause == "has_link")
        #expect(SearchToken.code.filterClause == "has_code")
        #expect(SearchToken.places.filterClause == "has_location")
        #expect(SearchToken.pinned.filterClause == "pinned")
        #expect(SearchToken.visibility(.private).filterClause == #"visibility == "PRIVATE""#)
        #expect(SearchToken.space(name: "spaces/studio", title: "Studio").filterClause == #"space == "spaces/studio""#)
        #expect(SearchToken.date(.thisWeek).filterClause == #"created_ts > now - duration("168h")"#)
    }

    @Test func `everything combines with and, and Mine comes from the scope`() {
        let query = SearchQuery(text: "afford  door", tokens: [.tag("reading"), .space(name: "spaces/studio", title: "Studio")])
        #expect(query.filter(creator: "users/you") == #"content.contains("afford") && content.contains("door") && tag in ["reading"] && space == "spaces/studio" && creator == "users/you""#)
        #expect(SearchQuery().filter() == nil)
        #expect(query.removingSpace().spaceToken == nil)
    }

    @Test func `quotes in search text are escaped`() throws {
        let filter = try #require(SearchQuery(text: #"say "hi"\"#).filter())
        #expect(try matches(filter, facts(content: #"they say "hi"\ twice"#)))
    }

    @Test func `the filter the server gets is the filter the local copy runs`() throws {
        let query = SearchQuery(text: "afford", tokens: [.tag("reading"), .date(.thisWeek)])
        let filter = try #require(query.filter(creator: "users/you"))
        #expect(try matches(filter, facts(content: "Affordances vs. signifiers #reading", created: now.addingTimeInterval(-86_400))))
        #expect(try !matches(filter, facts(content: "Affordances #reading", creator: "users/mira")))
    }

    @Test func `a view's pinned visibility and Space are found`() throws {
        #expect(try MemoFilter(#"visibility == "PUBLIC" && tag in ["x"]"#).pinnedVisibility == .public)
        #expect(try MemoFilter(#"tag in ["x"] || visibility == "PUBLIC""#).pinnedVisibility == nil)
        #expect(try MemoFilter(#"space == "spaces/studio""#).pinnedSpace == "spaces/studio")
    }
}

@Suite struct `Filters described as tokens` {
    @Test func `a tag and a flag read as their labels`() throws {
        #expect(try MemoFilter(#"tag in ["idea"] && pinned"#).tokens() == [.tag("idea"), .pinned])
        #expect(try MemoFilter("has_incomplete_tasks").tokens() == [.openTasks])
    }

    @Test func `every token's own clause round-trips`() throws {
        let tokens: [SearchToken] = [.tag("a b"), .openTasks, .tasks, .links, .code, .places, .pinned, .date(.thisWeek), .visibility(.protected), .space(name: "spaces/x", title: "Studio")]
        for token in tokens {
            #expect(try MemoFilter(token.filterClause).tokens { _ in "Studio" } == [token])
        }
    }

    @Test func `anything a token can't write has no description`() throws {
        #expect(try MemoFilter(#"tag in ["a", "b"]"#).tokens() == nil)
        #expect(try MemoFilter("pinned || has_link").tokens() == nil)
        #expect(try MemoFilter("!pinned").tokens() == nil)
    }
}
