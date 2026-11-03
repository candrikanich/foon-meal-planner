import Foundation
import Testing
@testable import Foon

/// The after-dinner prompt's own card (#122): the same answer as the notification's buttons.
@Suite struct DinnerPromptAnswerTests {
    private let night = UUID()
    private let member = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let id: String

    init() { id = ReminderID.afterDinner(me: member, night: night, meal: UUID()) }

    private var payload: ReminderPayload { ReminderPayload(route: .rate(night: night, member: member), dinnerAt: nil) }

    @Test func aReactionIsTheSameAnswerAsTheNotificationsButton() throws {
        for kind in ReactionKind.allCases {
            let answered = try #require(DinnerPrompt.answer(.reaction(kind), id: id, payload: payload, now: now))
            let button = try #require(ReminderResponse.outcome(id: id, action: ReminderCenter.reactAction(kind),
                                                               payload: payload, now: now))
            #expect(answered.dinner == button.dinner)
            #expect(answered.answer == button.answer)
            #expect(answered.cancels == button.cancels)
        }
    }

    @Test func wasntHomeIsTheSameAnswerAsTheNotificationsButton() throws {
        let answered = try #require(DinnerPrompt.answer(.wasntHome, id: id, payload: payload, now: now))
        let button = try #require(ReminderResponse.outcome(id: id, action: ReminderCenter.wasntHomeAction, payload: payload,
                                                           now: now))
        #expect(answered.dinner == DinnerAnswer(nightID: night, memberID: member, answer: .wasntHome, at: now))
        #expect(answered.dinner == button.dinner)
        #expect(answered.answer.response == "done")
    }

    @Test func aFollowUpAnswersWhatItFollowed() throws {
        let answered = try #require(DinnerPrompt.answer(.reaction(.good), id: ReminderID.followUp(of: id), payload: payload,
                                                        now: now))
        #expect(answered.answer.id == id)
        #expect(answered.cancels == [ReminderID.followUp(of: id)])
    }

    @Test func nothingToAnswerWithoutTheNightAndPerson() {
        let old = ReminderPayload(route: .dinnerCard, dinnerAt: nil)
        #expect(DinnerPrompt.answer(.reaction(.good), id: id, payload: old, now: now) == nil)
        #expect(DinnerPrompt.answer(.reaction(.good), id: id, payload: nil, now: now) == nil)
        #expect(DinnerPrompt.answer(.reaction(.good), id: UUID().uuidString, payload: payload, now: now) == nil,
                "a cook-mode timer isn't a prompt")
    }

    @Test func theCardReadsThePayloadTheAppWrote() throws {
        let read = try #require(ReminderPayload(userInfo: payload.userInfo))
        #expect(read == payload)
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func inbox() -> DinnerCardInbox {
    DinnerCardInbox(directory: FileManager.default.temporaryDirectory.appending(path: "foon-card-\(UUID().uuidString)"))
}

private func suite() -> UserDefaults {
    UserDefaults(suiteName: "foon.tests.card.\(UUID().uuidString)")!
}

private func card(_ answer: DinnerAnswer.Answer, night: UUID = UUID(), member: UUID = UUID(),
                  at: Date = now) -> DinnerPrompt.Answered {
    let id = ReminderID.afterDinner(me: member, night: night, meal: UUID())
    return DinnerPrompt.answer(answer, id: id, payload: ReminderPayload(route: .rate(night: night, member: member), dinnerAt: nil),
                               now: at)!
}

/// One file per answer in the App Group, like the share sheet's inbox, so the card and the app never write the same list.
@Suite struct DinnerCardInboxTests {
    @Test func whatTheCardSavedIsTakenOnceOldestFirst() throws {
        let inbox = inbox()
        let later = card(.wasntHome, at: now.addingTimeInterval(60)), earlier = card(.reaction(.good))
        try inbox.add(later)
        try inbox.add(earlier)
        #expect(inbox.takeAll() == [earlier, later])
        #expect(inbox.takeAll().isEmpty, "taking deletes them")
    }

    @Test func aFileThatCantBeReadIsThrownAway() throws {
        let inbox = inbox()
        try inbox.add(card(.reaction(.favorite)))
        try Data("not json".utf8).write(to: inbox.directory.appending(path: "junk.json"))
        #expect(inbox.takeAll().count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.directory.path()).isEmpty)
    }

    @Test func nothingSavedIsNothingToTake() {
        #expect(inbox().takeAll().isEmpty)
    }
}

/// The app takes the card's answers onto its own waiting lists, in the app's own defaults.
@Suite @MainActor struct CardAnswerIntakeTests {
    @Test func theyJoinTheWaitingListsAndLeaveTheInbox() throws {
        let inbox = inbox(), device = ReminderDevice(defaults: suite(), cardInbox: inbox)
        let answered = card(.reaction(.favorite))
        try inbox.add(answered)
        device.takeInCardAnswers()
        #expect(device.dinnerAnswers == [answered.dinner])
        #expect(device.answers == [answered.answer])
        #expect(inbox.takeAll().isEmpty)
    }

    @Test func aLaterAnswerForTheSameNightWins() throws {
        let inbox = inbox(), device = ReminderDevice(defaults: suite(), cardInbox: inbox)
        let night = UUID(), me = UUID()
        let other = DinnerAnswer(nightID: UUID(), memberID: me, answer: .wasntHome, at: now)
        device.add(DinnerAnswer(nightID: night, memberID: me, answer: .reaction(.notForMe), at: now))
        device.add(other)
        let fromTheCard = card(.reaction(.good), night: night, member: me, at: now.addingTimeInterval(60))
        try inbox.add(fromTheCard)
        device.takeInCardAnswers()
        #expect(device.dinnerAnswers == [other, fromTheCard.dinner])
    }

    @Test func anOlderCardAnswerDoesntWriteOverANewerOne() throws {
        let inbox = inbox(), device = ReminderDevice(defaults: suite(), cardInbox: inbox)
        let night = UUID(), me = UUID()
        let newer = DinnerAnswer(nightID: night, memberID: me, answer: .wasntHome, at: now.addingTimeInterval(60))
        device.add(newer)
        try inbox.add(card(.reaction(.good), night: night, member: me))
        device.takeInCardAnswers()
        #expect(device.dinnerAnswers == [newer])
    }

    @Test func noInboxIsNothingToTakeIn() {
        let device = ReminderDevice(defaults: suite())
        device.takeInCardAnswers()
        #expect(device.dinnerAnswers.isEmpty)
    }

    @Test func theStoreSendsTheCardsAnswersBeforeAScreenReads() async throws {
        actor Sent {
            var answers: [DinnerAnswer] = []
            func add(_ answer: DinnerAnswer) { answers.append(answer) }
        }
        let inbox = inbox(), device = ReminderDevice(defaults: suite(), cardInbox: inbox), sent = Sent()
        let answered = card(.reaction(.good), at: .now)
        try inbox.add(answered)
        var client = NotificationClient.preview
        client.answerDinner = { await sent.add($0) }
        let store = ReminderStore(householdID: UUID(), client: client, center: .none, device: device, session: ReminderSession())
        await store.sendWaitingAnswers()
        #expect(await sent.answers == [answered.dinner])
        #expect(device.dinnerAnswers.isEmpty)
    }
}
