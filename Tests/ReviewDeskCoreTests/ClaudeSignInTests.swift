import Foundation
import Testing
@testable import ReviewDeskCore

private let subscribed = ok(#"{"loggedIn":true,"authMethod":"claude.ai"}"#)

/// A federation sign-in whose token file exists, removed by the caller.
private func federation(workspace: String = "") throws -> (ClaudeSignIn, URL) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("oidc-\(UUID()).jwt")
    try Data("eyJhbGciOi.token.sig".utf8).write(to: file)
    let signIn = ClaudeSignIn(method: .federation, ruleID: "fdrl_01abc", organizationID: "1f0c3b5e-8a8f-4c1e-9d3e-2b6f7a9c0d11",
                              serviceAccountID: "svac_01xyz", workspaceID: workspace, tokenFile: file.path)
    return (signIn, file)
}

@Test func theSubscriptionAddsNoVariables() {
    #expect(ClaudeSignIn().environment.isEmpty)
    #expect(ClaudeSignIn().problem() == nil)
    // Ids left from an earlier federation setup are ignored while the subscription is picked.
    #expect(ClaudeSignIn(method: .subscription, ruleID: "fdrl_1", tokenFile: "/x").environment.isEmpty)
}

@Test func federationPassesItsIdsAndTokenFileOnly() throws {
    let (signIn, file) = try federation()
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(signIn.problem() == nil)
    #expect(signIn.environment == [
        "ANTHROPIC_FEDERATION_RULE_ID": "fdrl_01abc", "ANTHROPIC_ORGANIZATION_ID": "1f0c3b5e-8a8f-4c1e-9d3e-2b6f7a9c0d11",
        "ANTHROPIC_SERVICE_ACCOUNT_ID": "svac_01xyz", "ANTHROPIC_IDENTITY_TOKEN_FILE": file.path,
    ])
    #expect(try federation(workspace: "wrkspc_1").0.environment["ANTHROPIC_WORKSPACE_ID"] == "wrkspc_1")
    #expect(ClaudeSignIn(method: .federation, profile: "ci", ruleID: "fdrl_1").environment == ["ANTHROPIC_PROFILE": "ci"])
    #expect(Set(signIn.environment.keys).isSubset(of: ClaudeSignIn.variables))
    #expect(!ClaudeSignIn.variables.contains("ANTHROPIC_IDENTITY_TOKEN"))
}

@Test func federationIsCheckedBeforeARun() throws {
    let (signIn, file) = try federation()
    defer { try? FileManager.default.removeItem(at: file) }
    var missing = signIn
    missing.tokenFile = file.path + ".gone"
    #expect(missing.problem()?.contains("doesn't exist") == true)
    var folder = signIn
    folder.tokenFile = FileManager.default.temporaryDirectory.path
    #expect(folder.problem()?.contains("doesn't exist") == true)
    var pasted = signIn
    pasted.tokenFile = "eyJhbGciOiJSUzI1NiJ9.payload.sig"
    #expect(pasted.problem() == "enter the identity token file's path, not the token")
    var rule = signIn
    rule.ruleID = "sk-ant-api03-key"
    #expect(rule.problem()?.contains("fdrl_") == true)
    var organization = signIn
    organization.organizationID = "acme"
    #expect(organization.problem()?.contains("UUID") == true)
    var account = signIn
    account.serviceAccountID = ""
    #expect(account.problem()?.contains("svac_") == true)

    let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let profile = ClaudeSignIn(method: .federation, profile: "ci")
    #expect(profile.problem(home: home.path)?.contains("no readable profile") == true)
    let configs = home.appendingPathComponent(".config/anthropic/configs")
    try FileManager.default.createDirectory(at: configs, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: configs.appendingPathComponent("ci.json"))
    #expect(profile.problem(home: home.path) == nil)
    #expect(ClaudeSignIn(method: .federation, profile: "../ci").problem(home: home.path)?.contains("letters, digits") == true)
}

@Test func theSignInIsReadFromSettings() throws {
    let defaults = try #require(UserDefaults(suiteName: "signin-\(UUID())"))
    #expect(ClaudeSignIn(defaults: defaults) == ClaudeSignIn())
    defaults.set("federation", forKey: ClaudeSignIn.Key.method)
    defaults.set(" fdrl_1 ", forKey: ClaudeSignIn.Key.ruleID)
    defaults.set("~/token.jwt", forKey: ClaudeSignIn.Key.tokenFile)
    let signIn = ClaudeSignIn(defaults: defaults)
    #expect(signIn.method == .federation && signIn.ruleID == "fdrl_1" && signIn.tokenFile == "~/token.jwt")
    defaults.set("api_key", forKey: ClaudeSignIn.Key.method)
    #expect(ClaudeSignIn(defaults: defaults).method == .subscription)
}

@Test func onlyClaudeGetsTheFederationVariables() throws {
    let (signIn, file) = try federation()
    defer { try? FileManager.default.removeItem(at: file) }
    let base = ["HOME": "/h", "ANTHROPIC_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t", "CLAUDE_CODE_OAUTH_TOKEN": "o",
                "ANTHROPIC_IDENTITY_TOKEN": "eyJ.literal", "ANTHROPIC_FEDERATION_RULE_ID": "fdrl_from_shell", "ANTHROPIC_PROFILE": "shell"]
    // Another tool, or the subscription: no key, token or federation setting from the shell gets through.
    let plain = ProcessRunner.childEnvironment(base)
    for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_IDENTITY_TOKEN",
                "ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_PROFILE"] {
        #expect(plain[key] == nil)
    }
    #expect(plain["HOME"] == "/h")
    // Federation: its own variables, still with every key and literal token stripped.
    let claude = ProcessRunner.childEnvironment(base, signIn: signIn.environment)
    #expect(claude["ANTHROPIC_FEDERATION_RULE_ID"] == "fdrl_01abc" && claude["ANTHROPIC_IDENTITY_TOKEN_FILE"] == file.path)
    #expect(claude["ANTHROPIC_API_KEY"] == nil && claude["ANTHROPIC_IDENTITY_TOKEN"] == nil && claude["ANTHROPIC_PROFILE"] == nil)
    // Nothing but federation variables is taken from a sign-in.
    let smuggled = ProcessRunner.childEnvironment(base, signIn: ["ANTHROPIC_API_KEY": "k", "ANTHROPIC_IDENTITY_TOKEN": "t", "PATH": "/evil"])
    #expect(smuggled["ANTHROPIC_API_KEY"] == nil && smuggled["ANTHROPIC_IDENTITY_TOKEN"] == nil && smuggled["PATH"] != "/evil")
}

@Test func theRunnerPassesTheSignInToClaudeOnly() async throws {
    let (signIn, file) = try federation()
    defer { try? FileManager.default.removeItem(at: file) }
    let runner = ProcessRunner(paths: ["claude": "/usr/bin/env", "codex": "/usr/bin/env"], claudeSignIn: { signIn })
    let claude = try await runner.run("claude", []).text
    #expect(claude.contains("ANTHROPIC_FEDERATION_RULE_ID=fdrl_01abc\n"))
    #expect(claude.contains("ANTHROPIC_IDENTITY_TOKEN_FILE=\(file.path)\n"))
    let codex = try await runner.run("codex", []).text
    #expect(!codex.contains("ANTHROPIC_FEDERATION_RULE_ID"))
}

@Test func federationRunsWithoutAStoredLoginButNeverWithAKey() async throws {
    let (signIn, file) = try federation()
    defer { try? FileManager.default.removeItem(at: file) }
    let answer = ok(#"{"type":"result","is_error":false,"result":"fine"}"#)
    for status in [#"{"loggedIn":false,"authMethod":"none"}"#, #"{"loggedIn":true,"authMethod":"claude.ai"}"#, "not json"] {
        let runner = FakeRunner { call in call.args.first == "auth" ? ok(status) : answer }
        #expect(try await AIReviewer(runner: runner, claudeSignIn: { signIn }).ask(.claudeCode, prompt: "p") == "fine")
    }
    for method in ["api_key", "api_key_helper", "apiKeyHelper"] {
        let runner = FakeRunner { call in call.args.first == "auth" ? ok(#"{"loggedIn":true,"authMethod":"\#(method)"}"#) : answer }
        await #expect(throws: AIError.notSubscription("Claude Code is authenticated via \(method)")) {
            try await AIReviewer(runner: runner, claudeSignIn: { signIn }).ask(.claudeCode, prompt: "p")
        }
        #expect(runner.calls.count == 1) // never ran the prompt
    }
    // A missing token file stops the run before Claude Code is asked anything.
    var gone = signIn
    gone.tokenFile = file.path + ".gone"
    let missing = gone
    let runner = FakeRunner { _ in subscribed }
    await #expect(throws: AIError.self) { try await AIReviewer(runner: runner, claudeSignIn: { missing }).ask(.claudeCode, prompt: "p") }
    #expect(runner.calls.isEmpty)
}

@Test func theSubscriptionStillRefusesEverythingButClaudeAI() async {
    let runner = FakeRunner { _ in ok(#"{"loggedIn":true,"authMethod":"workload_identity"}"#) }
    await #expect(throws: AIError.notSubscription("Claude Code is authenticated via workload_identity")) {
        try await AIReviewer(runner: runner).ask(.claudeCode, prompt: "p")
    }
}

@Test func theStatusNamesTheSignIn() async throws {
    let (signIn, file) = try federation()
    defer { try? FileManager.default.removeItem(at: file) }
    let runner = FakeRunner { call in call.args.first == "--version" ? ok("2.1.3 (Claude Code)\n") : ok(#"{"loggedIn":false}"#) }
    let status = await AIReviewer(runner: runner, claudeSignIn: { signIn }).status(.claudeCode)
    #expect(status == ProviderStatus(version: "2.1.3", detail: "Signs in with workload identity federation", isReady: true))
}
