import Foundation
import Synchronization
import Testing
@testable import Foon

struct CookStepsTests {
    @Test(arguments: [
        ("Simmer 30 minutes, stirring now and then.", [1800]),
        ("Bake for 1 1/2 hours.", [5400]),
        ("Rest 20-25 min before slicing.", [1200]),
        ("Boil for an hour, then cool 10 mins.", [3600, 600]),
        ("Microwave 45 seconds.", [45]),
        ("Roast ½ hour.", [1800]),
        ("Cook 2 to 3 minutes per side.", [120]),
        ("Cook 1 to 1 1/2 hours.", [3600]),
        ("Braise 1-1 1/2 hours.", [3600]),
        ("Simmer 1 hour 30 minutes.", [5400]),
        ("Simmer 1 hour and 15 minutes.", [4500]),
        ("Bake 45 min-1 hour.", [2700]),
        ("Bake 1½ hours.", [5400]),
        ("Chill 2¼ hours.", [8100])
    ])
    func findsTheTimers(step: String, seconds: [Int]) {
        #expect(CookSteps.timers(in: step).map(\.seconds) == seconds)
    }

    @Test func labelsAreTheWordsThatSetThem() {
        #expect(CookSteps.timers(in: "Simmer 30 minutes.").map(\.label) == ["30 minutes"])
    }

    @Test func ignoresStepsWithoutTimes() {
        #expect(CookSteps.timers(in: "Add 2 cans of beans and 1 onion.").isEmpty)
        #expect(CookSteps.timers(in: "Heat oven to 350 degrees.").isEmpty)
        #expect(CookSteps.timers(in: "Serves 4.").isEmpty)
    }

    @Test func clocks() {
        #expect(CookSteps.clock(65) == "1:05")
        #expect(CookSteps.clock(3750) == "1:02:30")
        #expect(CookSteps.clock(-3) == "0:00")
    }
}

@MainActor
struct CookTimersTests {
    @Test func aTimerSchedulesItsAlertAndStoppingCancelsIt() async throws {
        let scheduled = Mutex<[(UUID, TimeInterval)]>([])
        let cancelled = Mutex<[UUID]>([])
        let start = Date(timeIntervalSince1970: 1_000_000)
        let timers = CookTimers(notifier: .init(
            schedule: { id, _, _, after in scheduled.withLock { $0.append((id, after)) }; return true },
            cancel: { id in cancelled.withLock { $0.append(id) } }
        ), now: { start })
        timers.start(CookSteps.Timer(seconds: 1800, label: "30 minutes"), dish: "chili")
        let running = try #require(timers.running.first)
        #expect(running.remaining(at: start.addingTimeInterval(60)) == 1740)
        await timers.settle()
        #expect(scheduled.withLock { $0 }.map(\.1) == [1800])
        timers.stop(running.id)
        #expect(timers.running.isEmpty)
        #expect(cancelled.withLock { $0 }.contains(running.id))
        #expect(!timers.alertsOff)
    }

    @Test func stoppingWhileTheAlertIsStillBeingScheduledCancelsItAfterward() async throws {
        let events = Mutex<[String]>([])
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (parked, parkedSignal) = AsyncStream<Void>.makeStream()
        let timers = CookTimers(notifier: .init(
            schedule: { _, _, _, _ in
                parkedSignal.yield()
                for await _ in gate { break }  // the permission prompt, say
                events.withLock { $0.append("scheduled") }
                return true
            },
            cancel: { _ in events.withLock { $0.append("cancelled") } }
        ))
        timers.start(CookSteps.Timer(seconds: 60, label: "1 minute"), dish: "eggs")
        for await _ in parked { break }
        let id = try #require(timers.running.first?.id)
        timers.stop(id)
        open.yield()
        open.finish()
        await timers.settle()
        for _ in 0..<100 where events.withLock({ $0.last }) != "cancelled" { await Task.yield() }
        #expect(events.withLock { $0 }.last == "cancelled", "the alert is cancelled after it was scheduled, not before")
    }

    @Test func withAlertsOffItSaysSo() async {
        let timers = CookTimers(notifier: .init(schedule: { _, _, _, _ in false }, cancel: { _ in }))
        timers.start(CookSteps.Timer(seconds: 60, label: "1 minute"), dish: "eggs")
        await timers.settle()
        #expect(timers.alertsOff)
    }

    @Test func leavingStopsEverything() {
        let cancelled = Mutex(0)
        let timers = CookTimers(notifier: .init(schedule: { _, _, _, _ in true },
                                                cancel: { _ in cancelled.withLock { $0 += 1 } }))
        timers.start(CookSteps.Timer(seconds: 60, label: "1 minute"), dish: "eggs")
        timers.start(CookSteps.Timer(seconds: 120, label: "2 minutes"), dish: "eggs")
        timers.stopAll()
        #expect(timers.running.isEmpty)
        #expect(cancelled.withLock { $0 } >= 2)
    }

    @Test func alertsShowWithSoundInTheForeground() {
        #expect(CookAlertPresenter.foregroundOptions == [.banner, .sound, .list])
    }

    @Test func voiceOverHearsDurations() {
        #expect(CookSteps.spoken(245).contains("4 minutes"))
    }
}
