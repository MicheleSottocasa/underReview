import Testing
@testable import ReviewDeskCore

@Test func readsTheRiskNotesSectionByQuestion() throws {
    let body = """
    Adds org invites.

    ## Risk notes
    - **Data changes:** new `invites` table, backfill of 2M rows
    - **Permission impact:** invite endpoint checks org membership
    - Performance concerns: none
    - **Failure handling:**
      email sending retries 3 times
    - **Anything I'm unsure about:** the unique index on (org, email)

    ## Screenshots
    none
    """
    let notes = try #require(Risk.notes(in: body))
    #expect(notes.byQuestion[.data] == ["new `invites` table, backfill of 2M rows"])
    #expect(notes.byQuestion[.access] == ["invite endpoint checks org membership"])
    #expect(notes.byQuestion[.scale] == ["none"])
    #expect(notes.byQuestion[.failure] == ["email sending retries 3 times"])
    #expect(notes.unsure == ["the unique index on (org, email)"])
    #expect(!notes.markdown.contains("Screenshots"))
}

@Test func riskNotesAreOptionalAndTheTemplateParses() throws {
    #expect(Risk.notes(in: "Just a fix.") == nil)
    let notes = try #require(Risk.notes(in: Risk.template))
    #expect(notes.byQuestion.isEmpty && notes.unsure.isEmpty)
    // A sentence that merely mentions data isn't a label.
    let prose = try #require(Risk.notes(in: "**Risk notes**\nThe data in this table is shared by every tenant in the cluster."))
    #expect(prose.byQuestion.isEmpty)
}

@Test func spotsDataLayerFiles() {
    let paths = ["app/migrations/0042_invites.py", "app/models.py", "db/schema.rb", "q.sql", "app/views.py", "README.md"]
    #expect(Risk.dataFiles(paths) == ["app/migrations/0042_invites.py", "app/models.py", "db/schema.rb", "q.sql"])
}

@Test func keyAreasCarryTheirRiskQuestion() {
    #expect(KeyArea(path: "a", reason: "", risk: "access").question == .access)
    #expect(KeyArea(path: "a", reason: "", risk: "other").question == nil)
    #expect(KeyArea(path: "a", reason: "").question == nil)
}
