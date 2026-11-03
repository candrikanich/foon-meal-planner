import Foundation
import Testing
@testable import Foon

/// The after-dinner prompt's own card (#122): it answers into the same waiting list the app sends from, in the App Group.
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

    @Test func savingPutsBothOnTheWaitingLists() throws {
        let device = ReminderDevice(defaults: suite(), shared: suite())
        let answered = try #require(DinnerPrompt.answer(.reaction(.favorite), id: id, payload: payload, now: now))
        device.add(answered)
        #expect(device.dinnerAnswers == [answered.dinner])
        #expect(device.answers == [answered.answer])
    }

    @Test func theCardReadsThePayloadTheAppWrote() throws {
        let read = try #require(ReminderPayload(userInfo: payload.userInfo))
        #expect(read == payload)
    }
}

/// The waiting lists live in the App Group, so the content extension and the app share them. What an older build left in the
/// app's own defaults moves over once.
@Suite struct ReminderDeviceSharedQueueTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func dinner(_ answer: DinnerAnswer.Answer) -> DinnerAnswer {
        DinnerAnswer(nightID: UUID(), memberID: UUID(), answer: answer, at: now)
    }

    @Test func answersGoToTheSharedSuiteAndChoicesStayOnThePhone() {
        let own = suite(), shared = suite()
        let device = ReminderDevice(defaults: own, shared: shared)
        let member = UUID()
        device.add(dinner(.wasntHome))
        device.add(ReminderAnswer(id: "foon.reminder.x", response: "done", at: now))
        device.add(CheckInAnswer(nightID: UUID(), memberID: member, home: true))
        device.setOptedIn(true, for: member)

        let fromTheOtherSide = ReminderDevice(defaults: suite(), shared: shared)
        #expect(fromTheOtherSide.dinnerAnswers.count == 1)
        #expect(fromTheOtherSide.answers.count == 1)
        #expect(fromTheOtherSide.checkIns.count == 1)
        #expect(!fromTheOtherSide.isOptedIn(member))
        #expect(device.isOptedIn(member))
    }

    @Test func whatAnOlderBuildLeftMovesOverOlderFirst() {
        let own = suite(), shared = suite()
        let old = ReminderDevice(defaults: own, shared: own)
        let waiting = dinner(.reaction(.good)), checkIn = CheckInAnswer(nightID: UUID(), memberID: UUID(), home: false)
        let tapped = ReminderAnswer(id: "foon.reminder.a", response: "done", at: now)
        old.add(waiting)
        old.add(checkIn)
        old.add(tapped)
        old.setOptedIn(true, for: checkIn.memberID)
        // The new card answered before the app had run since the update.
        let fromTheCard = dinner(.reaction(.favorite))
        ReminderDevice(defaults: suite(), shared: shared).add(fromTheCard)

        ReminderDevice.moveQueues(from: own, to: shared)

        let device = ReminderDevice(defaults: own, shared: shared)
        #expect(device.dinnerAnswers == [waiting, fromTheCard])
        #expect(device.checkIns == [checkIn])
        #expect(device.answers == [tapped])
        #expect(old.dinnerAnswers.isEmpty && old.checkIns.isEmpty && old.answers.isEmpty, "gone from the old place")
        #expect(device.isOptedIn(checkIn.memberID), "choices aren't moved")
    }

    @Test func movingAgainChangesNothing() {
        let own = suite(), shared = suite()
        let waiting = dinner(.wasntHome)
        ReminderDevice(defaults: own, shared: own).add(waiting)
        ReminderDevice.moveQueues(from: own, to: shared)
        ReminderDevice.moveQueues(from: own, to: shared)
        #expect(ReminderDevice(defaults: own, shared: shared).dinnerAnswers == [waiting])
    }

    @Test func clearingEmptiesBoth() {
        let own = suite(), shared = suite()
        let device = ReminderDevice(defaults: own, shared: shared)
        let member = UUID()
        device.add(dinner(.wasntHome))
        device.add(ReminderAnswer(id: "foon.reminder.b", response: "done", at: now))
        device.add(CheckInAnswer(nightID: UUID(), memberID: member, home: true))
        device.setOptedIn(true, for: member)
        device.clear()
        #expect(device.dinnerAnswers.isEmpty && device.answers.isEmpty && device.checkIns.isEmpty)
        #expect(!device.isOptedIn(member))
    }
}

private func suite() -> UserDefaults {
    UserDefaults(suiteName: "foon.tests.shared.\(UUID().uuidString)")!
}
