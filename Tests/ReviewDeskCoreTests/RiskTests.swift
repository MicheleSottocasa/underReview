import Foundation
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

@Test func reviewsAnswerEachRiskQuestion() throws {
    let json = #"{"summary":"s","findings":[],"keyAreas":[],"risks":[{"question":"data","level":"high","answer":"Backfills 2M rows."},{"question":"scale","level":"none","answer":"No queries."}]}"#
    let result = try JSONDecoder().decode(ReviewResult.self, from: Data(json.utf8))
    #expect(result.risk(.data)?.rank == 3)
    #expect(result.risk(.scale)?.level == "none")
    #expect(result.risk(.access) == nil)
    // Reviews saved before risk answers still load.
    #expect(try JSONDecoder().decode(ReviewResult.self, from: Data(#"{"summary":"s","findings":[]}"#.utf8)).risks.isEmpty)
}

@Test func schemaRequiresRiskAnswersForEveryQuestion() throws {
    let schema = try #require(try JSONSerialization.jsonObject(with: Data(AIContext.schema.utf8)) as? [String: Any])
    #expect((schema["required"] as? [String])?.contains("risks") == true)
    let risks = (schema["properties"] as? [String: Any])?["risks"] as? [String: Any]
    let item = (risks?["items"] as? [String: Any])?["properties"] as? [String: Any]
    let questions = (item?["question"] as? [String: Any])?["enum"] as? [String]
    #expect(questions == RiskQuestion.allCases.map(\.rawValue))
}
