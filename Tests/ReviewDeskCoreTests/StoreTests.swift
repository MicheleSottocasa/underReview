import Foundation
import Testing
@testable import ReviewDeskCore

@Test func organizationRoundTripsThroughJSONFile() throws {
    let file = JSONFile<Organization>(FileManager.default.temporaryDirectory.appendingPathComponent("org-\(UUID()).json"))
    defer { try? FileManager.default.removeItem(at: file.url) }
    #expect(file.load(default: Organization()) == Organization())

    var org = Organization()
    let project = org.addFolder("Backend")
    org.place("stack:o/r#1", in: project.id)
    org.notes["pr:X"] = "check migrations"
    try file.save(org)
    #expect(file.load(default: Organization()) == org)
}

@Test func deletingFolderRemovesSubfoldersAndUnfilesItems() {
    var org = Organization()
    let project = org.addFolder("P")
    let child = org.addFolder("C", in: project.id)
    let grandchild = org.addFolder("G", in: child.id)
    let other = org.addFolder("Other")
    org.place("pr:a", in: grandchild.id)
    org.place("pr:b", in: other.id)

    org.deleteFolder(project.id)

    #expect(org.folders == [other])
    #expect(org.placements == ["pr:b": other.id])
}

@Test func itemHasSingleLocation() {
    var org = Organization()
    let a = org.addFolder("A"), b = org.addFolder("B")
    org.place("stack:o/r#2", in: a.id)
    org.place("stack:o/r#2", in: b.id)
    #expect(org.items(in: a.id).isEmpty)
    #expect(org.items(in: b.id) == ["stack:o/r#2"])
    org.place("stack:o/r#2", in: nil)
    #expect(org.placements.isEmpty)
}

@Test func unfollowHidesAndFollowRestores() {
    var org = Organization()
    org.follow(id: "PR_1", url: "https://github.com/o/r/pull/1")
    org.unfollow(id: "PR_1")
    #expect(org.followed.isEmpty && org.unfollowed == ["PR_1"])
    org.follow(id: "PR_1", url: "https://github.com/o/r/pull/1")
    #expect(org.unfollowed.isEmpty)
}
