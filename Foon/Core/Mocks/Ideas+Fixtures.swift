import Foundation

extension IdeasClient {
    /// A couple of ideas from the sample family; every write succeeds.
    static func preview(requests: [DinnerRequest] = DinnerRequest.samples) -> IdeasClient {
        IdeasClient(requests: { _ in requests }, make: { _, _ in UUID() }, toggleMeToo: { _, _ in true },
                    update: { _, _ in })
    }
}

extension DinnerRequest {
    static let samples: [DinnerRequest] = [
        DinnerRequest(requestedByMemberID: Member.sampleFamily[3].id, title: "Crab legs", note: "since March",
                      plusOnes: [Member.sampleFamily[0].id, Member.sampleFamily[4].id]),
        DinnerRequest(requestedByMemberID: Member.sampleFamily[4].id, mealID: LibraryMeal.sampleLibrary[0].id,
                      targetDate: CalendarDay(Date()).adding(days: 2)),
        DinnerRequest(requestedByMemberID: Member.sampleFamily[1].id, title: "Sheet-pan gnocchi",
                      link: URL(string: "https://recipes.example/gnocchi"))
    ]
}
