import Foundation
import Synchronization
import Testing
@testable import Foon

@MainActor
struct ServingNotesTests {
    private let ann = Member.fixture(firstName: "Ann", guardian: true, userID: UUID())
    private let ben = Member.fixture(firstName: "Ben", userID: UUID())
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
    private let chili = UUID(), tacos = UUID()

    @Test func onlyForPeopleHomeInFamilyOrder() {
        let notes = [ServingNote(mealID: chili, memberID: nora.id, note: "keep it separate"),
                     ServingNote(mealID: chili, memberID: ann.id, note: "extra spicy"),
                     ServingNote(mealID: chili, memberID: ben.id, note: "no beans"),
                     ServingNote(mealID: tacos, memberID: nora.id, note: "plain")]
        #expect(ServingNotes.lines(notes, mealID: chili, home: [ann.id, nora.id], members: [ann, ben, nora])
            == ["Ann: extra spicy", "Nora: keep it separate"])
        #expect(ServingNotes.lines(notes, mealID: chili, home: [], members: [ann, ben, nora]).isEmpty)
    }

    @Test func peopleWriteTheirOwnParentsWriteAnyones() {
        #expect(ServingNotes.canWrite(for: ben, me: ben, isParent: false))
        #expect(!ServingNotes.canWrite(for: nora, me: ben, isParent: false))
        #expect(ServingNotes.canWrite(for: nora, me: ann, isParent: true))
    }

    @Test func lengthCountsLikeTheServer() {
        #expect(ServingNote.length("  no beans \n") == 8)
        #expect(ServingNote.length(String(repeating: "👍🏽", count: 70)) == 140, "skin-tone emoji are two code points each")
    }

    @Test func dayCardsCarryTheNotes() {
        let night = WeekNight(id: UUID(), date: CalendarDay(year: 2026, month: 11, day: 2), effort: .normal,
                              dinnerTime: nil, mealID: chili, mealName: "Chili", quickPick: nil, locked: false,
                              attendance: [nora.id: true, ben.id: false])
        let notes = [ServingNote(mealID: chili, memberID: nora.id, note: "keep it separate"),
                     ServingNote(mealID: chili, memberID: ben.id, note: "no beans")]
        let card = WeekStore.card(for: night, members: [ann, ben, nora], notes: { meal, home in
            ServingNotes.lines(notes, mealID: meal, home: home, members: [ann, ben, nora])
        })
        #expect(card.servingNotes == ["Nora: keep it separate"], "Ben is away")
    }
}

@MainActor
struct ServingNoteStoreTests {
    @Test func savesThenRereadsAndRefusesTooLong() async {
        let saved = Mutex<[(UUID, UUID, String)]>([])
        let meal = LibraryMeal.fixture(name: "Chili"), member = UUID()
        var client = LibraryClient.fake(meals: { _ in [meal] })
        client.setServingNote = { mealID, memberID, note in saved.withLock { $0.append((mealID, memberID, note)) } }
        client.servingNotes = { _ in [ServingNote(mealID: meal.id, memberID: member, note: "no beans")] }
        let store = LibraryStore(householdID: UUID(), client: client)
        #expect(await store.setServingNote("  no beans ", mealID: meal.id, memberID: member))
        #expect(saved.withLock { $0 }.map(\.2) == ["no beans"], "trimmed")
        #expect(store.servingNotes(for: meal.id).map(\.note) == ["no beans"])
        #expect(!(await store.setServingNote(String(repeating: "x", count: 121), mealID: meal.id, memberID: member)))
        #expect(store.errorMessage != nil)
        #expect(saved.withLock { $0 }.count == 1, "too long never reaches the server")
    }
}

@MainActor
struct ServingNoteRefreshTests {
    @Test func aRefreshPicksUpNotesWrittenOnAnotherPhone() async {
        let meal = LibraryMeal.fixture(name: "Chili"), nora = UUID()
        let written = Mutex(false)
        var client = LibraryClient.fake(meals: { _ in [meal] })
        client.servingNotes = { _ in
            written.withLock { $0 } ? [ServingNote(mealID: meal.id, memberID: nora, note: "plain")] : []
        }
        let store = LibraryStore(householdID: UUID(), client: client)
        await store.load(members: [])
        #expect(store.servingNotes.isEmpty)
        written.withLock { $0 = true }
        await store.refreshReactions(members: [])
        #expect(store.servingNotes(for: meal.id).map(\.note) == ["plain"])
    }

    @Test func emojiThatDontFitAreCaughtHere() async {
        let store = LibraryStore(householdID: UUID(), client: .fake())
        #expect(!(await store.setServingNote(String(repeating: "👍🏽", count: 70), mealID: UUID(), memberID: UUID())))
        #expect(store.errorMessage?.contains("120") == true)
    }
}
