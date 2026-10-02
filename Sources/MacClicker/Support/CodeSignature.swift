import Foundation
import Security

/// Identifies the running build the same way the keychain does.
///
/// The designated requirement is exactly the right fingerprint here. Signed with a
/// real identity it reads like `identifier "com.amalmehta.MacClicker" and
/// certificate leaf…` and stays identical across rebuilds, so the stored key is
/// never needlessly rewritten. Ad-hoc signed it is cdhash-based and therefore
/// different after every build — which is precisely when the keychain item *does*
/// need reclaiming.
enum CodeSignature {

    static var current: String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return "unknown"
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return "unknown" }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement
        else { return "unknown" }

        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess,
              let text
        else { return "unknown" }

        return text as String
    }
}
