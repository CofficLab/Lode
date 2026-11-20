import AppKit
import XCTest

/// Lode 全应用冒烟测试：用独立 bundle id 的测试宿主启动真实应用，
/// 覆盖内核装配、数据库工作区、聊天尾栏与设置窗口。
final class LodeSmokeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dataRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LodeUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchEnvironment["LODE_UI_TEST_DATA_ROOT"] = dataRoot.path
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        app.activate()
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning {
            app.terminate()
        }
        if let dataRoot {
            try? FileManager.default.removeItem(at: dataRoot)
        }
        app = nil
        dataRoot = nil
    }

    func testLaunchShowsDatabaseWorkspaceChatAndSettings() {
        waitForMainWindow()

        XCTAssertTrue(
            anyElement("database.empty.add-connection").waitForExistence(timeout: 20),
            "Database workspace did not become visible.\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            anyElement("lode.chat.pane").waitForExistence(timeout: 10),
            "Chat trailing pane is missing.\n\(app.debugDescription)"
        )

        // SwiftUI toolbar wrappers can replace the button's identifier with the
        // container's, so match the visible control by label as well.
        let settingsButton = button(
            identifiers: ["lode.toolbar.settings"],
            labels: ["Gear Shape", "Settings", "齿轮"]
        )
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), app.debugDescription)
        settingsButton.click()

        XCTAssertTrue(
            anyElement("lode.settings.ready").waitForExistence(timeout: 20),
            "Settings window did not become ready.\n\(app.debugDescription)"
        )
        XCTAssertGreaterThanOrEqual(app.windows.count, 2)
    }

    func testSQLiteConnectionRoundTripAndQuery() throws {
        waitForMainWindow()

        let fixtureURL = try makeSQLiteFixture()
        let addButton = anyElement("database.empty.add-connection")
        XCTAssertTrue(addButton.waitForExistence(timeout: 20), app.debugDescription)
        addButton.click()

        let form = app.sheets.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 10), app.debugDescription)

        let nameField = form.textFields.element(boundBy: 0)
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), form.debugDescription)
        replaceText(in: nameField, with: "UI Test DB")

        let pathField = form.textFields.element(boundBy: 1)
        XCTAssertTrue(pathField.exists, form.debugDescription)
        replaceText(in: pathField, with: fixtureURL.path)

        let saveButton = form.buttons["database.connection.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), form.debugDescription)
        XCTAssertTrue(saveButton.isEnabled, "SQLite connection form unexpectedly invalid: \(form.debugDescription)")
        saveButton.click()

        let savedRow = anyElement("database.saved-row.UI Test DB")
        XCTAssertTrue(savedRow.waitForExistence(timeout: 10), app.debugDescription)
        savedRow.click()

        let runButton = anyElement("database.query.run")
        XCTAssertTrue(runButton.waitForExistence(timeout: 20), "SQLite connection failed.\n\(app.debugDescription)")
        // OutlineGroup renders object categories collapsed by default; expand
        // "Tables" before asserting the table leaf exists.
        let tablesGroup = button(
            identifiers: ["database.objects.group.table"],
            labels: ["Tables (1)"]
        )
        XCTAssertTrue(tablesGroup.waitForExistence(timeout: 20), app.debugDescription)
        app.activate()
        tablesGroup.click()
        let customersRow = anyElement("database.objects.row.customers")
        XCTAssertTrue(
            customersRow.waitForExistence(timeout: 20)
                || element(withText: "customers").waitForExistence(timeout: 5),
            "Connected database did not load its table list.\n\(app.debugDescription)"
        )

        // The embedded editor's wrapper identifier is swallowed by its host
        // NSViewRepresentable, so match the remaining text view in the window.
        let editor = app.textViews.matching(
            NSPredicate(format: "identifier != %@", "lumi.conversation-input.editor")
        ).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        replaceText(in: editor, with: "SELECT COUNT(*) AS total FROM customers;")
        runButton.click()

        XCTAssertTrue(
            element(withText: "total").waitForExistence(timeout: 20),
            "Query results did not appear.\n\(app.debugDescription)"
        )
    }

    // MARK: - Helpers

    /// Typing long strings key-by-key is unreliable when the machine is busy;
    /// paste once and verify the field actually received the whole value.
    private func replaceText(in element: XCUIElement, with text: String) {
        app.activate()
        element.click()
        element.typeKey("a", modifierFlags: .command)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        element.typeKey("v", modifierFlags: .command)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (element.value as? String) == text {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(element.value as? String, text, "Field did not receive pasted text")
    }

    private func waitForMainWindow() {
        XCTAssertTrue(
            anyElement("lode.main.ready").waitForExistence(timeout: 60),
            "Main window did not finish booting.\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// macOS SwiftUI often exposes plain text only as an AX value, not a label.
    private func element(withText text: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "label == %@ OR value == %@ OR identifier == %@",
            text, text, text
        )
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    /// Toolbar and composite SwiftUI controls often expose a container
    /// identifier instead of the one applied to the button itself.
    private func button(identifiers: [String], labels: [String]) -> XCUIElement {
        let predicates = identifiers.map { NSPredicate(format: "identifier == %@", $0) }
            + labels.map { NSPredicate(format: "label == %@", $0) }
        return app.buttons.matching(NSCompoundPredicate(orPredicateWithSubpredicates: predicates)).firstMatch
    }

    private func makeSQLiteFixture() throws -> URL {
        let url = dataRoot.appendingPathComponent("ui-test.sqlite")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            url.path,
            """
            CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
            INSERT INTO customers (name) VALUES ('Ada'), ('Grace');
            """,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Failed to create SQLite fixture")
        return url
    }
}
