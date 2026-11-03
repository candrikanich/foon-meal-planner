import Foundation
import Testing
@testable import Foon

private typealias F = PlannerFixture

/// Balanced's Time to plan says how many new ideas are waiting (docs/spec.md → Time to plan).
struct IdeasWaitingTests {
    /// Time to plan goes Sunday the 8th at 9am.
    private let fire = F.at(8, 9)

    private func idea(by asker: Member = F.ben, entered: Member? = nil, daysBefore: Double = 1) -> ReminderIdea {
        ReminderIdea(createdAt: fire.addingTimeInterval(-daysBefore * 24 * 60 * 60), requestedBy: asker.id,
                     enteredBy: (entered ?? asker).id)
    }

    private func timeToPlan(_ ideas: [ReminderIdea], preset: HouseholdSettings.NotificationPreset = .balanced,
                            members: [Member] = F.family) -> PlannedReminder? {
        var settings = F.settings
        settings.notificationPreset = preset
        var inputs = F.inputs(members: members, settings: settings, now: F.at(8, 8))
        inputs.snapshot = ReminderSnapshot(pulledAt: F.at(8, 8), weeks: [], ideas: ideas)
        return F.of(.timeToPlan, NotificationPlanner.plan(inputs)).first
    }

    @Test func balancedSaysHowManyNewIdeasAreWaiting() throws {
        let reminder = try #require(timeToPlan([idea(), idea(by: F.kim)]))
        #expect(reminder.title == "Time to plan the week")
        #expect(reminder.body == "2 new ideas are waiting.")
        #expect(reminder.route == .week(F.day(8)))
        #expect(try #require(timeToPlan([idea()])).body == "1 new idea is waiting.")
    }

    @Test func onlyOthersNewIdeasFromThePastWeekCount() throws {
        let ann = F.ann
        var gone = F.ben
        gone.status = .removed
        let ideas = [
            idea(by: ann),
            idea(by: F.kim, entered: ann),
            idea(daysBefore: 8),
            idea(by: gone),
            ReminderIdea(createdAt: fire.addingTimeInterval(60), requestedBy: F.kim.id, enteredBy: F.kim.id)
        ]
        let reminder = try #require(timeToPlan(ideas, members: [ann, gone, F.kim]))
        #expect(reminder.body == ReminderText.timeToPlanBody,
                "theirs, entered by them, over a week old, from someone removed, or after it goes: none count")
    }

    @Test func lightAndEngagedKeepTheUsualWords() throws {
        #expect(try #require(timeToPlan([idea()], preset: .light)).body == ReminderText.timeToPlanBody)
        #expect(try #require(timeToPlan([idea()], preset: .engaged)).body == ReminderText.timeToPlanBody,
                "Engaged planners have the evening digest")
    }

    @Test func aNewCountIsANewReminderSoTheScheduledOneIsReplaced() throws {
        let none = try #require(timeToPlan([]))
        let one = try #require(timeToPlan([idea()]))
        let two = try #require(timeToPlan([idea(), idea(by: F.kim)]))
        #expect(none.id == ReminderID.timeToPlan(me: F.ann.id, week: F.day(8)), "no ideas: the same id as before")
        #expect(Set([none.id, one.id, two.id]).count == 3)
    }

    @Test func anOlderCacheWithoutIdeasStillReads() throws {
        let old = try JSONEncoder().encode(OldSnapshot(pulledAt: fire, weeks: []))
        #expect(try JSONDecoder().decode(ReminderSnapshot.self, from: old).ideas.isEmpty)
        let snapshot = ReminderSnapshot(pulledAt: fire, weeks: [], ideas: [idea()])
        #expect(try JSONDecoder().decode(ReminderSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    private struct OldSnapshot: Encodable {
        let pulledAt: Date
        let weeks: [ReminderWeek]
    }
}
