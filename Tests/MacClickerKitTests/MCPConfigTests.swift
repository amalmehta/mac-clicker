import XCTest
@testable import MacClickerKit

final class MCPConfigTests: XCTestCase {

    private func parse(_ json: String) throws -> [MCPServerConfig] {
        try MCPConfigFile.parse(Data(json.utf8))
    }

    func testParsesTheClaudeDesktopShape() throws {
        let servers = try parse("""
        {"mcpServers": {"notes": {"command": "npx", "args": ["-y", "server-filesystem"]}}}
        """)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].name, "notes")
        XCTAssertEqual(servers[0].command, "npx")
        XCTAssertEqual(servers[0].args, ["-y", "server-filesystem"])
        XCTAssertTrue(servers[0].enabled, "absent 'enabled' should mean on")
    }

    func testServersComeBackInAStableOrder() throws {
        let servers = try parse("""
        {"mcpServers": {"zulu": {"command": "a"}, "alpha": {"command": "b"}}}
        """)
        XCTAssertEqual(servers.map(\.name), ["alpha", "zulu"])
    }

    func testReadsEnvironmentAndDisabledFlag() throws {
        let servers = try parse("""
        {"mcpServers": {"x": {"command": "c", "env": {"TOKEN": "abc"}, "enabled": false}}}
        """)
        XCTAssertEqual(servers[0].env, ["TOKEN": "abc"])
        XCTAssertFalse(servers[0].enabled)
    }

    func testErrorsNameTheOffendingServer() {
        XCTAssertThrowsError(try parse("""
        {"mcpServers": {"good": {"command": "a"}, "broken": {"args": []}}}
        """)) { error in
            XCTAssertEqual(error as? MCPConfigError, .missingCommand("broken"))
        }
    }

    func testRejectsAFileWithoutServers() {
        XCTAssertThrowsError(try parse("{}")) {
            XCTAssertEqual($0 as? MCPConfigError, .missingServersKey)
        }
        XCTAssertThrowsError(try parse("[]")) {
            XCTAssertEqual($0 as? MCPConfigError, .notAnObject)
        }
    }

    func testTheBundledExampleIsValid() throws {
        let servers = try MCPConfigFile.parse(Data(MCPConfigFile.example.utf8))
        XCTAssertEqual(servers.count, 1)
    }
}

final class MCPToolNameTests: XCTestCase {

    func testQualifiesWithTheServerName() {
        XCTAssertEqual(MCPToolName.qualified(server: "notes", tool: "search"), "mcp_notes_search")
    }

    func testTwoServersWithTheSameToolDoNotCollide() {
        let a = MCPToolName.qualified(server: "notes", tool: "search")
        let b = MCPToolName.qualified(server: "mail", tool: "search")
        XCTAssertNotEqual(a, b)
    }

    func testIllegalCharactersAreReplaced() {
        let name = MCPToolName.qualified(server: "my notes!", tool: "find/all")
        XCTAssertEqual(name, "mcp_my_notes__find_all")
        XCTAssertTrue(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
    }

    func testLongNamesStayWithinTheApiLimit() {
        let name = MCPToolName.qualified(
            server: String(repeating: "s", count: 80),
            tool: String(repeating: "t", count: 30)
        )
        XCTAssertLessThanOrEqual(name.count, 64)
        XCTAssertTrue(name.hasSuffix(String(repeating: "t", count: 30)),
                      "the tool name carries the meaning and should survive")
    }

    func testResolvesBackToItsServer() {
        let name = MCPToolName.qualified(server: "notes", tool: "search_files")
        let resolved = MCPToolName.resolve(name, among: ["mail", "notes"])
        XCTAssertEqual(resolved?.server, "notes")
        XCTAssertEqual(resolved?.tool, "search_files")
    }

    func testUnknownToolResolvesToNil() {
        XCTAssertNil(MCPToolName.resolve("point_at", among: ["notes"]))
        XCTAssertNil(MCPToolName.resolve("mcp_other_x", among: ["notes"]))
    }
}
