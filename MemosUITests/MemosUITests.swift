import XCTest

/// End-to-end flows against a local server seeded by `scripts/seed_dev_server.py`:
///
///     TEST_RUNNER_MEMOS_TEST_SERVER=http://localhost:5230 xcodebuild test -scheme Memos …
///
/// Each test checks what reached the server, not just what the screen shows.
final class MemosUITests: XCTestCase {
    private var server: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try XCTUnwrap(ProcessInfo.processInfo.environment["MEMOS_TEST_SERVER"], "Set TEST_RUNNER_MEMOS_TEST_SERVER")
    }

    private func launch(signedIn: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEMOS_DEV_RESET"] = "1"
        if signedIn {
            app.launchEnvironment["MEMOS_DEV_SERVER"] = server
            app.launchEnvironment["MEMOS_DEV_USER"] = "you"
            app.launchEnvironment["MEMOS_DEV_PASSWORD"] = "memos-dev"
        }
        app.launch()
        return app
    }

    // MARK: Flows

    @MainActor
    func testSignInWithPassword() throws {
        let app = launch(signedIn: false)
        let address = app.textFields["memos.example.com"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(server)
        app.buttons["Continue"].tap()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("you")
        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText("memos-dev")
        app.buttons["Sign In"].tap()

        XCTAssertTrue(app.staticTexts["Kiln is free Thursday evening if anyone wants to glaze. #studio"].waitForExistence(timeout: 15)
            || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Morning light'")).firstMatch.waitForExistence(timeout: 15))
    }

    @MainActor
    func testWrongPasswordIsExplained() throws {
        let app = launch(signedIn: false)
        let address = app.textFields["memos.example.com"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(server)
        app.buttons["Continue"].tap()
        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("you")
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText("wrong")
        app.buttons["Sign In"].tap()
        XCTAssertTrue(app.staticTexts["That username and password don’t match."].waitForExistence(timeout: 10))
    }

    @MainActor
    func testCaptureSavesAndUploads() throws {
        let app = launch()
        let marker = "uitest-\(UUID().uuidString.prefix(8))"
        let capture = app.descendants(matching: .any)["captureField"].firstMatch
        XCTAssertTrue(capture.waitForExistence(timeout: 15))
        capture.tap()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("Written by the UI test \(marker) #uitest")
        app.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.waitForExistence(timeout: 5))
        let uploaded = try waitForServer { try self.listMemos(filter: "content.contains(\"\(marker)\")") }
        XCTAssertEqual(uploaded.first?["visibility"] as? String, "PRIVATE")
        XCTAssertEqual(uploaded.first?["tags"] as? [String], ["uitest"])
        try deleteMemo(uploaded[0]["name"] as! String)
    }

    @MainActor
    func testSearchFindsOtherPeoplesMemos() throws {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["captureField"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Search"].firstMatch.tap()
        app.typeText("kiln")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Kiln is free'")).firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testReactingReachesTheServer() throws {
        let app = launch()
        let card = app.staticTexts["Commonplace book"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let react = app.buttons["React"].firstMatch
        XCTAssertTrue(react.waitForExistence(timeout: 5))
        react.tap()
        app.buttons["React with 🎉"].tap()

        let name = try XCTUnwrap(listMemos(filter: "content.contains(\"Commonplace\")").first?["name"] as? String)
        _ = try waitForServer {
            try self.memo(name)["reactions"].flatMap { ($0 as? [[String: Any]])?.filter { $0["reactionType"] as? String == "🎉" } } ?? []
        }
        // Tapping the count again removes it.
        let count = app.buttons["🎉 1"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        count.tap()
        _ = try waitForServer {
            let left = try self.memo(name)["reactions"].flatMap { ($0 as? [[String: Any]])?.filter { $0["reactionType"] as? String == "🎉" } } ?? []
            return left.isEmpty ? [[:]] : []
        }
    }

    // MARK: Server

    private func token() throws -> String {
        let response = try post("AuthService/SignIn", ["passwordCredentials": ["username": "you", "password": "memos-dev"]], token: nil)
        return try XCTUnwrap(response["accessToken"] as? String)
    }

    private func listMemos(filter: String) throws -> [[String: Any]] {
        try post("MemoService/ListMemos", ["filter": filter], token: token())["memos"] as? [[String: Any]] ?? []
    }

    private func memo(_ name: String) throws -> [String: Any] {
        try post("MemoService/GetMemo", ["name": name], token: token())
    }

    private func deleteMemo(_ name: String) throws {
        _ = try post("MemoService/DeleteMemo", ["name": name], token: token())
    }

    private func waitForServer(timeout: TimeInterval = 15, _ check: () throws -> [[String: Any]]) throws -> [[String: Any]] {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            let result = try check()
            if !result.isEmpty { return result }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("The server never saw the change")
        return []
    }

    private func post(_ method: String, _ body: [String: Any], token: String?) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(server!)/memos.api.\(method)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return (try? JSONSerialization.jsonObject(with: result ?? Data()) as? [String: Any]) ?? [:]
    }
}
