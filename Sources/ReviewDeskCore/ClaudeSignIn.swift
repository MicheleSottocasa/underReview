import Foundation

/// How Claude Code signs in. The default is the user's subscription login. Workload Identity Federation is opt-in:
/// Claude Code exchanges an OIDC token, read from a file on every exchange, for a short-lived Anthropic token. Neither
/// uses a static API key: ReviewDesk never takes one, and still strips every key and auth token from child processes.
/// The ids aren't secrets, so they're kept with the other settings; the token itself only ever lives in its file.
public struct ClaudeSignIn: Hashable, Sendable {
    public enum Method: String, Hashable, Sendable {
        case subscription
        case federation
    }

    public var method: Method
    /// An Anthropic profile (`~/.config/anthropic/configs/<name>.json`) holding the federation settings. When set, the
    /// ids and token file below aren't passed: the profile has its own.
    public var profile: String
    public var ruleID: String
    public var organizationID: String
    public var serviceAccountID: String
    /// Optional.
    public var workspaceID: String
    /// The OIDC token's path, never the token.
    public var tokenFile: String

    public init(method: Method = .subscription, profile: String = "", ruleID: String = "", organizationID: String = "",
                serviceAccountID: String = "", workspaceID: String = "", tokenFile: String = "") {
        (self.method, self.profile, self.ruleID, self.organizationID) = (method, profile, ruleID, organizationID)
        (self.serviceAccountID, self.workspaceID, self.tokenFile) = (serviceAccountID, workspaceID, tokenFile)
    }

    /// Where Settings › AI keeps it.
    public enum Key {
        public static let method = "claudeSignIn"
        public static let profile = "claudeFederation.profile"
        public static let ruleID = "claudeFederation.ruleID"
        public static let organizationID = "claudeFederation.organizationID"
        public static let serviceAccountID = "claudeFederation.serviceAccountID"
        public static let workspaceID = "claudeFederation.workspaceID"
        public static let tokenFile = "claudeFederation.tokenFile"
    }

    /// The saved choice; anything unknown is the subscription.
    public init(defaults: UserDefaults) {
        func value(_ key: String) -> String { (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        self.init(method: Method(rawValue: value(Key.method)) ?? .subscription, profile: value(Key.profile), ruleID: value(Key.ruleID),
                  organizationID: value(Key.organizationID), serviceAccountID: value(Key.serviceAccountID),
                  workspaceID: value(Key.workspaceID), tokenFile: value(Key.tokenFile))
    }

    /// Every variable federation is configured through. Only these are ever added to Claude Code's environment, and
    /// they're removed from every other one, so the shell ReviewDesk was started from can't switch the sign-in.
    /// `ANTHROPIC_IDENTITY_TOKEN` (the token itself) is never among them: it's stripped like an API key.
    public static let variables: Set<String> = [
        "ANTHROPIC_PROFILE", "ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_ORGANIZATION_ID", "ANTHROPIC_SERVICE_ACCOUNT_ID",
        "ANTHROPIC_WORKSPACE_ID", "ANTHROPIC_IDENTITY_TOKEN_FILE",
    ]

    /// What Claude Code gets on top of its stripped environment: nothing with the subscription.
    public var environment: [String: String] {
        guard method == .federation else { return [:] }
        if !profile.isEmpty { return ["ANTHROPIC_PROFILE": profile] }
        var env = ["ANTHROPIC_FEDERATION_RULE_ID": ruleID, "ANTHROPIC_ORGANIZATION_ID": organizationID,
                   "ANTHROPIC_SERVICE_ACCOUNT_ID": serviceAccountID,
                   "ANTHROPIC_IDENTITY_TOKEN_FILE": (tokenFile as NSString).expandingTildeInPath]
        if !workspaceID.isEmpty { env["ANTHROPIC_WORKSPACE_ID"] = workspaceID }
        return env
    }

    /// Why Claude Code can't run with this sign-in yet, or nil. Checked before every run: the token file has to exist
    /// and be readable (it's read again on every exchange), and the ids must look like Anthropic's.
    public func problem(home: String = NSHomeDirectory()) -> String? {
        guard method == .federation else { return nil }
        if !profile.isEmpty {
            guard profile.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }), !profile.hasPrefix(".") else {
                return "the Anthropic profile name can only hold letters, digits, - _ and ."
            }
            let file = (home as NSString).appendingPathComponent(".config/anthropic/configs/\(profile).json")
            guard FileManager.default.isReadableFile(atPath: file) else {
                return "workload identity federation: no readable profile at \((file as NSString).abbreviatingWithTildeInPath)"
            }
            return nil
        }
        guard ruleID.hasPrefix("fdrl_") else { return "workload identity federation needs the federation rule id (fdrl_…)" }
        guard UUID(uuidString: organizationID) != nil else { return "workload identity federation needs the organization id (a UUID)" }
        guard serviceAccountID.hasPrefix("svac_") else { return "workload identity federation needs the service account id (svac_…)" }
        let ids = [ruleID, organizationID, serviceAccountID, workspaceID]
        guard ids.allSatisfy({ !$0.contains(where: { $0.isWhitespace || $0.isNewline }) }) else {
            return "workload identity federation ids can't contain spaces"
        }
        guard !tokenFile.isEmpty else { return "workload identity federation needs the identity token file's path" }
        // A pasted JWT instead of its path: refuse it rather than keep a token in the settings.
        guard !tokenFile.hasPrefix("eyJ") else { return "enter the identity token file's path, not the token" }
        let path = (tokenFile as NSString).expandingTildeInPath
        var isFolder: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue else {
            return "the identity token file \(tokenFile) doesn't exist"
        }
        guard FileManager.default.isReadableFile(atPath: path) else { return "the identity token file \(tokenFile) isn't readable" }
        return nil
    }

    /// `claude auth status` methods that bill an API key: refused with either sign-in.
    // ponytail: the method Claude Code reports for federation isn't documented, so federation accepts any method
    // except these; anything naming a key counts as one.
    static func isAPIKey(_ authMethod: String) -> Bool {
        authMethod.lowercased().contains("key")
    }
}
