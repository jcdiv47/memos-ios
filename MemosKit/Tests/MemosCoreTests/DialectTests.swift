import Foundation
import Testing
@testable import MemosAPI

struct `Speaking to Memos 0.31` {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func `routes move to memos.api.v1, under a sub-path too`() throws {
        let route = try #require(V1Route(url: URL(string: "https://example.com/memos/memos.api.MemoService/ListMemos")!))
        #expect(route.method == "MemoService/ListMemos")
        #expect(route.url.absoluteString == "https://example.com/memos/memos.api.v1.MemoService/ListMemos")
    }

    @Test func `renamed methods take their 0.31 name`() throws {
        let route = try #require(V1Route(url: URL(string: "http://host:9030/memos.api.UserService/ListUserStats")!))
        #expect(route.url.path() == "/memos.api.v1.UserService/ListAllUserStats")
    }

    @Test func `other paths are left alone`() {
        #expect(V1Route(url: URL(string: "http://host/file/attachments/1/a.jpg")!) == nil)
    }

    @Test func `requests rename parent and resource names`() throws {
        let comment = try json(V1Translation.request("MemoService/CreateMemoComment", Data(#"{"parent":"memos/a","comment":{"content":"hi"}}"#.utf8)))
        #expect(comment["name"] as? String == "memos/a")
        #expect(comment["parent"] == nil)

        let users = try json(V1Translation.request("UserService/BatchGetUsers", Data(#"{"names":["users/mira","users/you"]}"#.utf8)))
        #expect(users["usernames"] as? [String] == ["mira", "you"])

        let sso = try json(V1Translation.request("AuthService/SignIn", Data(#"{"ssoCredentials":{"identityProvider":"identity-providers/1","code":"c"}}"#.utf8)))
        #expect((sso["ssoCredentials"] as? [String: Any])?["idpName"] as? String == "identity-providers/1")
    }

    @Test func `responses take the current names`() throws {
        let comments = try json(V1Translation.response("MemoService/ListMemoComments", Data(#"{"memos":[{"name":"memos/b"}]}"#.utf8)))
        #expect((comments["comments"] as? [Any])?.count == 1)

        let tokens = try json(V1Translation.response("UserService/ListPersonalAccessTokens", Data(#"{"personalAccessTokens":[{"createdAt":"2026-01-01T00:00:00Z","expiresAt":"2026-02-01T00:00:00Z"}]}"#.utf8)))
        let token = try #require((tokens["personalAccessTokens"] as? [[String: Any]])?.first)
        #expect(token["createTime"] != nil && token["expireTime"] != nil && token["createdAt"] == nil)

        let stats = try json(V1Translation.response("UserService/ListUserStats", Data(#"{"stats":[{"name":"users/a/stats","tagCount":{"x":1}}]}"#.utf8)))
        let first = try #require((stats["userStats"] as? [[String: Any]])?.first)
        #expect(first["tagCounts"] != nil)

        let signIn = try json(V1Translation.response("AuthService/SignIn", Data(#"{"accessToken":"t","accessTokenExpiresAt":"2026-01-01T00:00:00Z"}"#.utf8)))
        #expect(signIn["accessTokenExpireTime"] as? String == "2026-01-01T00:00:00Z")
    }

    @Test func `releases before 0.31 are turned away`() {
        #expect(ServerDialect.supports(version: "0.31.0"))
        #expect(ServerDialect.supports(version: "0.32.1"))
        #expect(ServerDialect.supports(version: "26.10.19-dev.f0ee2fd"))
        #expect(ServerDialect.supports(version: "dev"))
        #expect(!ServerDialect.supports(version: "0.30.0"))
        #expect(!ServerDialect.supports(version: "0.25.3"))
    }

    @Test func `bodies of other methods pass through byte for byte`() {
        let body = Data(#"{"memos":[{"location":{"latitude":22.2855}}]}"#.utf8)
        #expect(V1Translation.response("MemoService/ListMemos", body) == body)
    }
}
