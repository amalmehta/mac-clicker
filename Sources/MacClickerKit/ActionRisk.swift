import Foundation

/// How much scrutiny an action needs before it runs.
public enum ActionRisk: String, Sendable, Equatable {
    /// Covered by the approval the user gave for this run.
    case routine
    /// Always asked about individually, however many times it comes up, because
    /// getting it wrong cannot be taken back.
    case consequential
}

/// Decides what may be done without asking again.
///
/// Deliberately pessimistic: anything that looks like it sends, spends, publishes or
/// destroys is `consequential`, and a false positive only costs one extra click while
/// a false negative sends a half-written email. Being free of AppKit, it is also
/// directly testable, which for a list like this matters more than usual.
public enum ActionClassifier {

    /// Words that mean an action leaves the machine, spends money, or cannot be
    /// undone. Matched case-insensitively against the control's label.
    ///
    /// "Cancel" is absent on purpose — it almost always aborts something, and
    /// treating it as dangerous trains people to click through the prompts.
    public static let consequentialTerms: Set<String> = [
        "send", "reply", "forward", "submit", "post", "publish", "tweet", "share",
        "invite", "delete", "remove", "trash", "erase", "empty", "discard", "destroy",
        "buy", "purchase", "pay", "order", "checkout", "subscribe", "unsubscribe",
        "transfer", "withdraw", "deposit", "confirm", "agree", "accept", "sign",
        "install", "uninstall", "restart", "shutdown", "logout", "quit", "format",
        "reset", "revoke", "deactivate", "archive", "block", "report", "merge",
        "push", "deploy", "release", "approve", "overwrite", "replace", "move",
        // Verbs that show up in tool names rather than on buttons. A tool is named
        // by its author, not by a UI designer, so the vocabulary is different.
        "write", "create", "edit", "update", "modify", "rename", "insert", "append",
        "upload", "commit", "execute", "run", "patch", "drop", "truncate", "kill",
        "revert", "restore", "clear", "purge", "disable", "enable", "grant"
    ]

    /// Verbs that only look. Their presence means a stemmed match elsewhere in the
    /// label is probably a noun — `get_posts` reads posts, it does not post.
    public static let readOnlyTerms: Set<String> = [
        "get", "list", "read", "search", "fetch", "query", "find", "show", "view",
        "describe", "count", "inspect", "lookup", "browse", "preview", "check"
    ]

    /// Applications this never acts in, whatever the user has allowed.
    ///
    /// Password managers and the keychain because the payoff for a mistake is the
    /// user's entire credential store; System Settings because it can disable the
    /// very protections that make this safe; terminals because pressing a button in
    /// one is indistinguishable from running arbitrary code.
    public static let blockedBundlePrefixes: [String] = [
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        "com.apple.Passwords",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.1password",
        "com.agilebits",
        "com.bitwarden",
        "com.lastpass",
        "com.dashlane",
        "com.amalmehta.MacClicker"
    ]

    /// `label` is a button title, or a tool name and its description. Tool names use
    /// a different vocabulary from buttons — `write_file`, `create_issue` — so both
    /// sets of terms are checked against whatever is supplied.
    public static func risk(label: String, role: String = "") -> ActionRisk {
        let words = tokens(in: label)

        // An exact match settles it, whatever else the label says: "get_and_delete"
        // still deletes.
        if !words.isDisjoint(with: consequentialTerms) { return .consequential }

        // Descriptions are written in the third person — "deletes local copies" —
        // so a light stem is needed to see them. But stemming alone would read
        // `get_posts` as posting, so it only counts when nothing in the label says
        // this merely looks at something.
        let stemmed = Set(words.map(stem))
        if !stemmed.isDisjoint(with: consequentialTerms),
           words.isDisjoint(with: readOnlyTerms) {
            return .consequential
        }

        return .routine
    }

    /// Just enough to turn "deletes" into "delete". Not a real stemmer, and should
    /// not become one: every rule added here is a new way to be wrong.
    private static func stem(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
        return String(word.dropLast())
    }

    public static func isBlocked(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else {
            // An app we cannot identify is an app we cannot vouch for.
            return true
        }
        let lowered = bundleID.lowercased()
        return blockedBundlePrefixes.contains { lowered.hasPrefix($0.lowercased()) }
    }

    /// Lowercased words, with punctuation and the ellipsis on menu items stripped,
    /// so "Send…" and "Send" classify the same.
    private static func tokens(in label: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.inverted
        return Set(
            label.lowercased()
                .components(separatedBy: separators)
                .filter { !$0.isEmpty }
        )
    }
}
