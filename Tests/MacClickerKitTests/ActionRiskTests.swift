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
