import Foundation
import Supabase
import Testing
@testable import Foon

/// Rating dinner from the after-dinner notification, without opening the app (#122).
@Suite struct AfterDinnerAnswerTests {
    private let night = UUID()
    private let member = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var payload: ReminderPayload { ReminderPayload(route: .rate(night: night, member: member), dinnerAt: nil) }

    private func outcome(_ action: String, payload: ReminderPayload? = nil) -> ReminderResponse.Outcome? {
        ReminderResponse.outcome(id: ReminderID.afterDinner(me: member, night: night, meal: UUID()), action: action,
                                 payload: payload ?? self.payload, now: now)
    }

    @Test func eachReactionSavesWithoutOpeningTheApp() throws {
        for kind in ReactionKind.allCases {
            let answered = try #require(outcome(ReminderCenter.reactAction(kind)))
            #expect(answered.dinner == DinnerAnswer(nightID: night, memberID: member, answer: .reaction(kind), at: now))
            #expect(answered.route == nil)
            #expect(answered.answer.response == "done")
        }
    }

    @Test func wasntHomeSaysSoWithoutOpeningTheApp() throws {
        let answered = try #require(outcome(ReminderCenter.wasntHomeAction))
        #expect(answered.dinner?.answer == .wasntHome)
        #expect(answered.route == nil)
    }

    @Test func somethingElseOpensTheCardWithoutAnswering() throws {
        let opened = try #require(outcome(ReminderCenter.somethingElseAction))
        #expect(opened.dinner == nil)
        #expect(opened.route == .rate(night: night, member: member))
    }

    @Test func tappingItOpensTheCard() throws {
        let tapped = try #require(outcome("com.apple.UNNotificationDefaultActionIdentifier"))
        #expect(tapped.dinner == nil)
        #expect(tapped.route == .rate(night: night, member: member))
    }

    @Test func aPromptFromBeforeTheButtonsCantBeAnsweredFromThem() {
        // Scheduled by an older build: it carries no night or person, so a button has nothing to answer.
        #expect(outcome(ReminderCenter.reactAction(.good), payload: ReminderPayload(route: .dinnerCard, dinnerAt: nil)) == nil)
    }

    @Test func itsPayloadSurvivesTheTrip() {
        #expect(ReminderPayload(userInfo: payload.userInfo) == payload)
        #expect(ReminderPayload(userInfo: ["route": "rate", "night": night.uuidString]) == nil)
        #expect(ReminderPayload(userInfo: ["route": "dinner"])?.route == .dinnerCard)
    }

    @Test func itHasItsOwnButtonsInTheSpecsOrder() {
        let reminder = PlannedReminder(id: "x", kind: .afterDinner, nightID: night, fireAt: now, dinnerAt: nil, title: "",
                                       body: "", route: .rate(night: night, member: member))
        #expect(ReminderCenter.category(for: reminder) == ReminderCenter.afterDinnerCategory)
        let old = PlannedReminder(id: "x", kind: .afterDinner, nightID: night, fireAt: now, dinnerAt: nil, title: "", body: "",
                                  route: .dinnerCard)
        #expect(ReminderCenter.category(for: old) == nil)
        #expect(ReactionKind.allCases.map { ReminderCenter.reaction(fromAction: ReminderCenter.reactAction($0)) }
            == ReactionKind.allCases)
        #expect(ReminderCenter.reaction(fromAction: ReminderCenter.wasntHomeAction) == nil)
    }
}

@Suite @MainActor struct DinnerAnswerDeliveryTests {
    private actor Sent {
        var answers: [DinnerAnswer.Answer] = []
        func add(_ answer: DinnerAnswer.Answer) { answers.append(answer) }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func device() -> ReminderDevice {
        ReminderDevice(defaults: UserDefaults(suiteName: "dinner.\(UUID().uuidString)")!)
    }

    private func answer(_ answer: DinnerAnswer.Answer, ago: TimeInterval = 60) -> DinnerAnswer {
        DinnerAnswer(nightID: UUID(), memberID: UUID(), answer: answer, at: now.addingTimeInterval(-ago))
    }

    private func client(_ work: @escaping @Sendable (DinnerAnswer.Answer) async throws -> Void) -> NotificationClient {
        var client = NotificationClient.preview
        client.answerDinner = { try await work($0.answer) }
        return client
    }

    @Test func theyGoInOrderAndComeOffTheList() async {
        let device = device(), sent = Sent()
        device.add(answer(.reaction(.good)))
        device.add(answer(.wasntHome))
        await DinnerAnswerDelivery.send(device: device, client: client { await sent.add($0) }, now: now)
        #expect(await sent.answers == [.reaction(.good), .wasntHome])
        #expect(device.dinnerAnswers.isEmpty)
    }

    @Test func noSignalKeepsThemForNextTime() async {
        let device = device(), first = answer(.reaction(.favorite)), second = answer(.wasntHome)
        device.add(first)
        device.add(second)
        await DinnerAnswerDelivery.send(device: device, client: client { _ in throw URLError(.notConnectedToInternet) }, now: now)
        #expect(device.dinnerAnswers == [first, second])
    }

    @Test func aFinalNoComesOffTheListAndTheRestStillGo() async {
        let device = device(), sent = Sent()
        device.add(answer(.reaction(.notForMe)))
        device.add(answer(.reaction(.good)))
        await DinnerAnswerDelivery.send(device: device, client: client { answer in
            if answer == .reaction(.notForMe) { throw PostgrestError(code: "FD004", message: "they eat separately") }
            await sent.add(answer)
        }, now: now)
        #expect(await sent.answers == [.reaction(.good)])
        #expect(device.dinnerAnswers.isEmpty)
    }

    @Test func notAllowedIsntFinalUntilItsTooOld() async {
        let device = device(), waiting = answer(.reaction(.good)), stale = answer(.reaction(.good), ago: DinnerAnswer.keptFor + 1)
        device.add(stale)
        device.add(waiting)
        await DinnerAnswerDelivery.send(device: device, client: client { _ in
            throw PostgrestError(code: "42501", message: "permission denied")
        }, now: now)
        #expect(device.dinnerAnswers == [waiting], "the old one goes without being sent; the new one waits")
    }

    @Test func signingOutLeavesNoneWaiting() {
        let device = device()
        device.add(answer(.wasntHome))
        device.clear()
        #expect(device.dinnerAnswers.isEmpty)
    }
}

@MainActor
struct DinnerCardReplacesWaitingAnswerTests {
    @Test func rateOnTheCardDropsTheLockScreensOlderAnswerForThatNight() async {
        let device = ReminderDevice(defaults: UserDefaults(suiteName: "dinnercard.\(UUID().uuidString)")!)
        let night = UUID(), me = UUID()
        let other = DinnerAnswer(nightID: UUID(), memberID: me, answer: .wasntHome, at: .now)
        device.add(DinnerAnswer(nightID: night, memberID: me, answer: .reaction(.notForMe), at: .now))
        device.add(other)
        let client = DinnerClient(logs: { _, _ in [] }, confirm: { _ in UUID() }, react: { _, _, _ in UUID() },
                                  correct: { _, _ in }, nights: { _, _, _ in [] }, setNotHome: { _, _ in })
        let store = DinnerStore(householdID: UUID(), client: client, waiting: device)
        #expect(await store.react(nightID: night, memberID: me, .favorite))
        #expect(device.dinnerAnswers == [other])
    }
}
