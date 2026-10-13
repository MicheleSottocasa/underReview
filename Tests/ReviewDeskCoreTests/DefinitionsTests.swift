import Testing
@testable import ReviewDeskCore

@Test func pythonFunctionsClassesAndConstantsWithDocstrings() {
    let source = """
    MAX_INVITES = 50

    class InviteService(Base):
        \"\"\"Sends invites.

        Admins only.
        \"\"\"

        def send(self, email: str,
                 org: Org) -> dict[str, int]:
            '''One invite.'''
            return {}

    # Builds the default service.
    def make():
        pass
    """
    let send = Definitions.find("send", path: "app/invites.py", source: source)
    #expect(send.map(\.kind) == ["method"])
    #expect(send.first?.line == 9)
    #expect(send.first?.declaration == "def send(self, email: str,\n             org: Org) -> dict[str, int]")
    #expect(send.first?.doc == "One invite.")
    let service = Definitions.find("InviteService", path: "app/invites.py", source: source).first
    #expect(service?.kind == "class")
    #expect(service?.declaration == "class InviteService(Base)")
    #expect(service?.doc == "Sends invites.\n\nAdmins only.")
    #expect(Definitions.find("MAX_INVITES", path: "a.py", source: source).first.map { [$0.kind, $0.declaration] } == ["constant", "MAX_INVITES = 50"])
    #expect(Definitions.find("make", path: "a.py", source: source).first?.doc == "Builds the default service.")
    // Calls and comparisons aren't definitions.
    #expect(Definitions.find("send", path: "a.py", source: "service.send(x)\nif send == 1: pass").isEmpty)
}

@Test func swiftDeclarationsStopAtTheBodyAndKeepDocComments() {
    let source = """
    /// Runs a command.
    /// Throws on timeout.
    @discardableResult
    public func run(_ tool: String,
                    args: [String] = []) async throws -> Result {
        fatalError()
    }

    /**
     * A pull request.
     */
    struct PullRequest: Codable {
        let id: String
        var title = ""
    }
    """
    let run = Definitions.find("run", path: "Shell.swift", source: source).first
    #expect(run?.kind == "function")
    #expect(run?.declaration == "public func run(_ tool: String,\n                args: [String] = []) async throws -> Result")
    #expect(run?.doc == "Runs a command.\nThrows on timeout.")
    let pr = Definitions.find("PullRequest", path: "a.swift", source: source).first
    #expect(pr.map { [$0.kind, $0.declaration, $0.doc ?? ""] } == ["struct", "struct PullRequest: Codable", "A pull request."])
    #expect(Definitions.find("id", path: "a.swift", source: source).first.map { [$0.kind, $0.declaration] } == ["constant", "let id: String"])
    #expect(Definitions.find("title", path: "a.swift", source: source).first?.kind == "variable")
}

@Test func javaScriptAndGoDeclarations() {
    let js = """
    /**
     * Formats a date.
     */
    export function formatDate(date, locale = "en") {
      return ""
    }
    export const LIMIT = 10;
    class Store {
      async load(id: string): Promise<void> {
      }
    }
    """
    let format = Definitions.find("formatDate", path: "util.ts", source: js).first
    #expect(format.map { [$0.kind, $0.declaration, $0.doc ?? ""] } == ["function", #"export function formatDate(date, locale = "en")"#, "Formats a date."])
    #expect(Definitions.find("LIMIT", path: "util.ts", source: js).first?.kind == "constant")
    #expect(Definitions.find("Store", path: "util.ts", source: js).first?.kind == "class")
    #expect(Definitions.find("load", path: "util.ts", source: js).first?.declaration == "async load(id: string): Promise<void>")

    let go = """
    // Client talks to the API.
    type Client struct {
    \tURL string
    }

    // Get fetches one item.
    func (c *Client) Get(id string) (Item, error) {
    \treturn Item{}, nil
    }

    func New() *Client { return nil }
    """
    let get = Definitions.find("Get", path: "client.go", source: go).first
    #expect(get.map { [$0.kind, $0.declaration, $0.doc ?? ""] } == ["method", "func (c *Client) Get(id string) (Item, error)", "Get fetches one item."])
    #expect(Definitions.find("Client", path: "client.go", source: go).first.map { [$0.kind, $0.doc ?? ""] } == ["type", "Client talks to the API."])
    #expect(Definitions.find("New", path: "client.go", source: go).first?.kind == "function")
}

@Test func unsupportedLanguagesFindNothing() {
    #expect(Definitions.find("main", path: "main.rs", source: "fn main() {}").isEmpty)
    #expect(!Definitions.isCovered("README.md"))
}

@Test func codeEndingInABlockCommentIsNoDoc() {
    let source = """
    func f() {}
    var y = 1 /* note */
    let x = 2

    /* Unclosed above
    stray text
     */
    func g() {}
    """
    #expect(Definitions.find("x", path: "a.swift", source: source).first.map { $0.doc == nil } == true)
    #expect(Definitions.find("g", path: "a.swift", source: source).first.map { $0.doc == nil } == true)
}

@Test func callsWithCallbacksAndTypeImportsAreNoDefinitions() {
    let spec = """
    import type Store from './store'
    describe('Store', function () {
      it("loads", () => {
      })
    })
    """
    #expect(Definitions.find("describe", path: "store.test.ts", source: spec).isEmpty)
    #expect(Definitions.find("it", path: "store.test.ts", source: spec).isEmpty)
    #expect(Definitions.find("Store", path: "store.test.ts", source: spec).isEmpty)
    // A Python import scan doesn't run on from one line into the next.
    #expect(Definitions.imports("from x\nimport y", path: "a.py") == ["y.py", "y/__init__.py"])
}

@Test func minifiedLinesAreSkipped() {
    let minified = "function load(a){" + String(repeating: "a(b);", count: 500) + "}"
    #expect(Definitions.find("load", path: "app.min.js", source: minified).isEmpty)
    #expect(Definitions.find("load", path: "app.js", source: "function load(a) {").count == 1)
}

@Test func identifierUnderTheClick() {
    #expect(Definitions.identifier(in: "x = make_service(a)", at: 7)?.name == "make_service")
    #expect(Definitions.identifier(in: "x = make_service(a)", at: 7)?.range == 4..<16)
    #expect(Definitions.identifier(in: "x = f(a)", at: 5) == nil) // the parenthesis
    #expect(Definitions.identifier(in: "n = 42", at: 4) == nil)
}

@Test func importsResolveToRepositoryPaths() {
    let python = "from .models import Invite, Org\nfrom app.tasks import send_email\nimport utils.dates\n"
    let paths = Definitions.imports(python, path: "app/invites/views.py")
    #expect(paths.contains("app/invites/models.py"))
    #expect(paths.contains("app/tasks.py"))
    #expect(paths.contains("app/tasks/send_email.py"))
    #expect(paths.contains("utils/dates.py"))
    let wrapped = Definitions.imports("from .services import (\n    send_invite,\n    revoke as cancel,\n)\n", path: "app/views.py")
    #expect(wrapped.contains("app/services.py"))
    #expect(wrapped.contains("app/services/send_invite.py"))
    #expect(wrapped.contains("app/services/revoke.py"))
    let js = "import { a } from './lib/date.js'\nconst b = require(\"../store\")\nimport React from 'react'"
    let jsPaths = Definitions.imports(js, path: "src/ui/App.tsx")
    #expect(jsPaths.contains("src/ui/lib/date.ts"))
    #expect(jsPaths.contains("src/store/index.ts"))
    #expect(!jsPaths.contains { $0.contains("react") })
}

@Test func rankingAndChangeStatus() {
    let make = { (path: String) in Definition(kind: "function", name: "f", path: path, line: 2, declaration: "def f()", doc: nil) }
    let ranked = Definitions.rank([make("other.py"), make("imported.py"), make("here.py")], from: "here.py", imported: ["imported.py"])
    #expect(ranked.map(\.path) == ["here.py", "imported.py", "other.py"])

    let files = [FileChange(filename: "a.py", status: "modified", additions: 1, deletions: 0, patch: "@@ -1,2 +1,3 @@\n x\n+def f():\n y")]
    #expect(Definitions.change(of: make("a.py"), in: files) == .added)
    var moved = make("a.py")
    moved.line = 1
    moved.declaration = "x\ndef f()"
    #expect(Definitions.change(of: moved, in: files) == .modified)
    #expect(Definitions.change(of: make("b.py"), in: files) == .untouched)
    #expect(Definitions.headLines("@@ -1,2 +1,2 @@\n x\n-y\n+z").map(\.text) == ["x", "z"])
}
