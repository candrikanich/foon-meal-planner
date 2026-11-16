import Foundation
import Testing
@testable import Foon

struct FavoritedByTests {
    private let ann = Member.fixture(firstName: "Ann")
    private let ben = Member.fixture(firstName: "Ben")
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
    private let owen = Member.fixture(firstName: "Owen", ageGroup: .kid)
    private let tacos = UUID()
    private let day = CalendarDay(year: 2026, month: 11, day: 1)
    private let en = Locale(identifier: "en_US")

    private func verdict(_ member: Member, _ kind: ReactionKind, on offset: Int = 0, meal: UUID? = nil) -> MealVerdict {
        MealVerdict(mealID: meal ?? tacos, memberID: member.id, kind: kind, reactedOn: day.adding(days: offset))
    }

    private func favoriters(_ verdicts: [MealVerdict], members: [Member]) -> [String] {
        (FavoritedBy.byMeal(verdicts: verdicts, members: members)[tacos] ?? []).map(\.firstName)
    }

    // MARK: Text

    @Test func noFavoritersSaysNothing() {
        #expect(FavoritedBy.text([], locale: en) == nil)
    }

    @Test func oneFavoriterNamesThem() {
        #expect(FavoritedBy.text([nora], locale: en) == "Nora's favorite")
    }

    @Test func twoFavoritersAreJoinedByTheLocale() {
        #expect(FavoritedBy.text([nora, ben], locale: en) == "Nora and Ben's favorite")
        #expect(FavoritedBy.text([nora, ben], locale: Locale(identifier: "es_ES")) == "Nora y Ben's favorite")
    }

    @Test func threeOrMoreFavoritersAreCounted() {
        #expect(FavoritedBy.text([ann, ben, nora], locale: en) == "Favorite of 3")
        #expect(FavoritedBy.text([ann, ben, nora, owen], locale: en) == "Favorite of 4")
    }

    // MARK: Who counts

    @Test func favoritersFollowTheHouseholdsMemberOrderNotTheOrderTheyReacted() {
        let verdicts = [verdict(nora, .favorite), verdict(ann, .favorite), verdict(ben, .favorite)]
        #expect(favoriters(verdicts, members: [ann, ben, nora]) == ["Ann", "Ben", "Nora"])
    }

    @Test func aLaterOtherReactionReplacesAnEarlierFavorite() {
        let verdicts = [verdict(nora, .favorite, on: 0), verdict(nora, .notForMe, on: 3), verdict(ann, .favorite)]
        #expect(favoriters(verdicts, members: [ann, nora]) == ["Ann"])
        let tired = [verdict(nora, .tiredOfIt, on: 2), verdict(nora, .favorite, on: 1)]
        #expect(favoriters(tired, members: [nora]).isEmpty)
    }

    @Test func aLaterFavoriteReplacesAnEarlierDislike() {
        let verdicts = [verdict(nora, .notForMe, on: 0), verdict(nora, .favorite, on: 2)]
        #expect(favoriters(verdicts, members: [nora]) == ["Nora"])
    }

    @Test func eachMemberCountsOnce() {
        let verdicts = [verdict(nora, .favorite, on: 0), verdict(nora, .favorite, on: 1)]
        #expect(favoriters(verdicts, members: [nora]) == ["Nora"])
    }

    @Test func removedMembersAndSeparateEatersAreLeftOut() {
        let gone = Member.fixture(firstName: "Rita", status: .removed)
        var baby = Member.fixture(firstName: "Bea", ageGroup: .kid)
        baby.eatsSeparately = true
        let verdicts = [gone, baby, ann].map { verdict($0, .favorite) }
        #expect(favoriters(verdicts, members: [gone, baby, ann]) == ["Ann"])
    }

    @Test func someoneAwayStillHasFavorites() {
        let away = Member.fixture(firstName: "Owen", status: .away, awayUntil: day.adding(days: 30))
        #expect(favoriters([verdict(away, .favorite)], members: [away]) == ["Owen"])
    }

    @Test func eachDishKeepsItsOwnFavoriters() {
        let mac = UUID()
        let map = FavoritedBy.byMeal(verdicts: [verdict(ann, .favorite), verdict(ben, .favorite, meal: mac)],
                                     members: [ann, ben])
        #expect(map[tacos]?.map(\.firstName) == ["Ann"])
        #expect(map[mac]?.map(\.firstName) == ["Ben"])
    }

    // MARK: Entry

    @Test func entriesExposeTheirFavoriters() {
        let mac = LibraryMeal.fixture(name: "Mac and cheese")
        let plain = LibraryMeal.fixture(name: "Tacos")
        let entries = LibraryQuery.entries(meals: [mac, plain], library: [mac, plain], history: [], allergies: [],
                                           favorites: [], favoritedBy: [mac.id: [nora, ben]])
        #expect(entries[0].favoritedBy == [nora, ben])
        #expect(entries[1].favoritedBy.isEmpty)
        #expect(LibraryText.favoritedBy(entries[0]) == FavoritedBy.text([nora, ben]))
        #expect(LibraryText.favoritedBy(entries[1]) == nil)
    }
}
