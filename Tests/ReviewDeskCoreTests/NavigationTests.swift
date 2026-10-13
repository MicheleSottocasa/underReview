import Testing
@testable import ReviewDeskCore

@Test func stepsToTheNeighbouringPositionAndStopsAtTheEnds() {
    let positions = [12, 3, 7, 7]
    #expect(Navigation.step(positions, from: 7, forward: true) == 12)
    #expect(Navigation.step(positions, from: 7, forward: false) == 3)
    #expect(Navigation.step(positions, from: 12, forward: true) == nil)
    #expect(Navigation.step(positions, from: 3, forward: false) == nil)
}

@Test func stepsFromAPositionThatIsNotInTheList() {
    #expect(Navigation.step([3, 7, 12], from: 5, forward: true) == 7)
    #expect(Navigation.step([3, 7, 12], from: 5, forward: false) == 3)
    #expect(Navigation.step([3, 7, 12], from: nil, forward: true) == 3)
    #expect(Navigation.step([3, 7, 12], from: nil, forward: false) == 12)
    #expect(Navigation.step([], from: nil, forward: true) == nil)
}
