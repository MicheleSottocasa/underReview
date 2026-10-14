import Testing
@testable import ReviewDeskCore

@Test func stepsToTheNeighbouringPositionAndStopsAtTheEnds() {
    let positions = [12, 3, 7, 7]
    #expect(Navigation.step(positions, from: 7, forward: true) == 12)
    #expect(Navigation.step(positions, from: 7, forward: false) == 3)
    #expect(Navigation.step(positions, from: 12, forward: true) == nil)
    #expect(Navigation.step(positions, from: 3, forward: false) == nil)
}

@Test func itemsSharingARowAreSeparateSteps() {
    // Three key areas: 0 and 2 start on row 5, 1 on row 9.
    let positions = [(5, 0), (9, 1), (5, 2)].map { Navigation.position(row: $0.0, item: $0.1, count: 3) }
    #expect(Set(positions).count == 3)
    let first = Navigation.step(positions, from: nil, forward: true)!
    #expect(Navigation.item(at: first, count: 3) == (5, 0))
    let second = Navigation.step(positions, from: first, forward: true)!
    #expect(Navigation.item(at: second, count: 3) == (5, 2))
    #expect(Navigation.item(at: Navigation.step(positions, from: second, forward: true)!, count: 3) == (9, 1))
    // From a comment on row 5 (no item), the next area is the first one on that row; the previous is before it.
    let comment = Navigation.position(row: 5, item: nil, count: 3)
    #expect(Navigation.step(positions, from: comment, forward: true) == first)
    #expect(Navigation.step(positions, from: comment, forward: false) == nil)
}

@Test func stepsFromAPositionThatIsNotInTheList() {
    #expect(Navigation.step([3, 7, 12], from: 5, forward: true) == 7)
    #expect(Navigation.step([3, 7, 12], from: 5, forward: false) == 3)
    #expect(Navigation.step([3, 7, 12], from: nil, forward: true) == 3)
    #expect(Navigation.step([3, 7, 12], from: nil, forward: false) == 12)
    #expect(Navigation.step([], from: nil, forward: true) == nil)
}

@Test func areaPositionSitsOnTheSelectedAreaOnlyOnItsRow() {
    let rows: [Int?] = [5, 9, nil]
    #expect(Navigation.areaPosition(cursor: 9, selected: 1, rows: rows, count: 3) == Navigation.position(row: 9, item: 1, count: 3))
    #expect(Navigation.areaPosition(cursor: 5, selected: 1, rows: rows, count: 3) == Navigation.position(row: 5, item: nil, count: 3))
    #expect(Navigation.areaPosition(cursor: nil, selected: 1, rows: rows, count: 3) == nil)
}

/// Regression: opening a key area from Focus drew the diff once before it was rendered, with no area rows yet but the
/// selected area's index set, and indexing the empty rows crashed the app.
@Test func areaPositionToleratesRowsNotRenderedYet() {
    #expect(Navigation.areaPosition(cursor: 4, selected: 0, rows: [], count: 2) == Navigation.position(row: 4, item: nil, count: 2))
    #expect(Navigation.areaPosition(cursor: nil, selected: 0, rows: [], count: 2) == nil)
    #expect(Navigation.areaPosition(cursor: 4, selected: 7, rows: [4], count: 1) == Navigation.position(row: 4, item: nil, count: 1))
}
