import XCTest
@testable import MacClickerKit

final class ActionRiskTests: XCTestCase {

    func testOrdinaryControlsAreRoutine() {
        for label in ["Mixer", "Zoom In", "Tracks", "Preferences", "Open", "Cancel", "Back"] {
            XCTAssertEqual(
                ActionClassifier.risk(label: label), .routine,
                "\(label) should not need re-asking"
            )
        }
    }

    func testIrreversibleControlsAreConsequential() {
        for label in ["Send", "Delete", "Move to Trash", "Publish", "Buy now", "Pay $40",
                      "Submit application", "Sign out", "Empty Trash", "Deploy"] {
            XCTAssertEqual(
                ActionClassifier.risk(label: label), .consequential,
                "\(label) must be asked about every time"
            )
        }
    }

    func testPunctuationAndCaseDoNotHideAnAction() {
        XCTAssertEqual(ActionClassifier.risk(label: "Send…"), .consequential)
        XCTAssertEqual(ActionClassifier.risk(label: "SEND"), .consequential)
        XCTAssertEqual(ActionClassifier.risk(label: "Send/Receive"), .consequential)
        XCTAssertEqual(ActionClassifier.risk(label: "  delete  "), .consequential)
    }

    func testCancelIsNotTreatedAsDangerous() {
        // Flagging the escape hatch teaches people to click through prompts.
        XCTAssertEqual(ActionClassifier.risk(label: "Cancel"), .routine)
    }

    func testSubstringsDoNotFalselyTrigger() {
        // "Resend" contains "send"; token matching must not treat it as the word.
        XCTAssertEqual(ActionClassifier.risk(label: "Resender settings"), .routine)
        XCTAssertEqual(ActionClassifier.risk(label: "Transferable"), .routine)
    }

    // MARK: - Tool names, which read differently from buttons

    func testReadOnlyToolsRunWithoutAsking() {
        for tool in ["search_files", "read_file", "list_directory", "get_issue",
                     "fetch_page", "query_database", "find_notes"] {
            XCTAssertEqual(
                ActionClassifier.risk(label: tool), .routine,
                "\(tool) only reads; asking about it would be noise"
            )
        }
    }

    func testToolsThatChangeThingsAreConsequential() {
        for tool in ["write_file", "create_issue", "delete_row", "send_message",
                     "update_record", "execute_sql", "commit_changes", "rename_file",
                     "upload_attachment", "kill_process"] {
            XCTAssertEqual(
                ActionClassifier.risk(label: tool), .consequential,
                "\(tool) changes something and must be confirmed"
            )
        }
    }

    func testADescriptionCanRevealTheRisk() {
        // Tool authors do not always name things carefully; the description is the
        // second chance to notice. Descriptions are third person, so "deletes".
        XCTAssertEqual(
            ActionClassifier.risk(label: "notes_sync — deletes local copies"),
            .consequential
        )
        XCTAssertEqual(
            ActionClassifier.risk(label: "mailbox — sends queued drafts"),
            .consequential
        )
    }

    func testAPluralNounIsNotMistakenForAVerb() {
        // Stemming makes "posts" look like "post" and "orders" like "order". A
        // read-only verb in the same label says it is a noun.
        for tool in ["get_posts", "list_orders", "search_reports", "fetch_releases",
                     "count_transfers"] {
            XCTAssertEqual(
                ActionClassifier.risk(label: tool), .routine,
                "\(tool) reads; the plural noun should not trip it"
            )
        }
    }

    func testAnExactMatchBeatsAReadOnlyVerb() {
        // "get_and_delete" still deletes.
        XCTAssertEqual(ActionClassifier.risk(label: "get_and_delete"), .consequential)
        XCTAssertEqual(ActionClassifier.risk(label: "list_then_send"), .consequential)
    }

    // MARK: - A real server's vocabulary

    /// The fourteen tools @modelcontextprotocol/server-filesystem actually exposes,
    /// captured from a live `tools/list`. Real names rather than invented ones, so
    /// editing the term list cannot quietly start asking about every file read — or
    /// quietly stop asking before a file is overwritten.
    func testTheFilesystemServerSplitsCorrectly() {
        let readOnly = [
            "read_file", "read_text_file", "read_media_file", "read_multiple_files",
            "list_directory", "list_directory_with_sizes", "directory_tree",
            "search_files", "get_file_info", "list_allowed_directories"
        ]
        let changesThings = ["write_file", "edit_file", "create_directory", "move_file"]

        for tool in readOnly {
            XCTAssertEqual(
                ActionClassifier.risk(label: tool), .routine,
                "\(tool) only reads — confirming it every time would be noise"
            )
        }
        for tool in changesThings {
            XCTAssertEqual(
                ActionClassifier.risk(label: tool), .consequential,
                "\(tool) alters the filesystem and must be confirmed"
            )
        }
    }

    // MARK: - Blocked applications

    func testSensitiveAppsAreBlocked() {
        for bundle in ["com.apple.keychainaccess", "com.1password.1password",
                       "com.apple.Terminal", "com.googlecode.iterm2",
                       "com.apple.systempreferences", "com.amalmehta.MacClicker"] {
            XCTAssertTrue(ActionClassifier.isBlocked(bundleID: bundle), bundle)
        }
    }

    func testOrdinaryAppsAreNotBlocked() {
        for bundle in ["com.apple.Preview", "com.google.Chrome", "com.apple.dt.Xcode"] {
            XCTAssertFalse(ActionClassifier.isBlocked(bundleID: bundle), bundle)
        }
    }

    func testUnidentifiableAppIsBlocked() {
        XCTAssertTrue(ActionClassifier.isBlocked(bundleID: nil))
        XCTAssertTrue(ActionClassifier.isBlocked(bundleID: ""))
    }

    func testBlockingIsCaseInsensitive() {
        XCTAssertTrue(ActionClassifier.isBlocked(bundleID: "COM.APPLE.TERMINAL"))
    }
}
