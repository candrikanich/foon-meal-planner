import Foundation
import Observation
import SwiftData

/// Goes up each time a person's data is cleared off the device, so a run still in flight from before can't write or schedule
/// anything after that. The screens' own lifetimes can't say so: covering them with cook mode makes them "disappear" too.
@MainActor
final class ReminderSession {
    static let shared = ReminderSession()
    private(set) var generation = 0

    func end() { generation += 1 }
}

/// Keeps what's scheduled on this device in step with `NotificationPlanner`: when the app comes to the foreground and when the
/// plan changes. It only ever touches its own identifiers, so cook-mode timers are safe. It needs two yeses: this person turned
/// reminders on, and the system allows notifications, which cook-mode timers may have asked for. Without both it schedules
/// nothing, logs nothing, and the app works as if none of this were here.
///
/// A plan changed on another phone reaches this one the next time Foon opens here. There's no background refresh or push yet,
/// so until then what's pending stays pending. That's why the planner won't schedule far ahead of its last read.
@Observable @MainActor
final class ReminderStore {
    /// Who and what the plan is for, from the household store.
    struct Context: Equatable, Sendable {
        var me: Member
        var members: [Member]
        var settings: HouseholdSettings
    }

    private(set) var permission: ReminderPermission = .notAsked
    /// An approved week, and something to say about it. Time to plan alone doesn't count: on a brand new household that would
    /// put the ask at first launch, before Foon has done anything for them.
    private(set) var hasRemindersToOffer = false
    private(set) var hasDeclined = false
    private(set) var isOptedIn = false

    let householdID: UUID
    private let client: NotificationClient
    private let center: ReminderCenter
    private let device: ReminderDevice
    private let now: () -> Date
    private var context: ModelContext?

    private var wanted: Context?
    private var isRunning = false
    private let session: ReminderSession
    private let generation: Int
    private var isStopped: Bool { session.generation != generation }

    init(householdID: UUID, client: NotificationClient, center: ReminderCenter = .system, device: ReminderDevice = ReminderDevice(),
         session: ReminderSession = .shared, context: ModelContext? = nil, now: @escaping () -> Date = { .now }) {
        self.session = session
        generation = session.generation
        self.householdID = householdID
        self.client = client
        self.center = center
        self.device = device
        self.context = context
        self.now = now
    }

    /// Whether to show the ask on This Week: once there's something to offer, whether or not cook-mode timers got permission first,
    /// and never again after "Not now". After a no in Settings the card couldn't do anything, so it's Family's link instead.
    var shouldAsk: Bool { !isOptedIn && !hasDeclined && hasRemindersToOffer && permission != .off }

    func attach(_ context: ModelContext) {
        self.context = context
    }

    /// Re-plans for this person. If a run is under way it picks this up when it's done, so an older plan can't land last.
    func replan(_ wanted: Context) async {
        self.wanted = wanted
        guard !isRunning, !isStopped else { return }
        isRunning = true
        defer { isRunning = false }
        while let next = self.wanted {
            self.wanted = nil
            await run(next)
        }
    }

    /// Before a screen reads the week, so it sees what was said on the lock screen.
    func sendWaitingCheckIns() async {
        await CheckInDelivery.send(device: device, client: client)
    }

    /// The card's answer reached the server, and it's newer than anything still waiting for that night.
    func forgetWaitingCheckIns(night: UUID, member: UUID) {
        device.removeCheckIns(night: night, member: member)
    }

    /// From a button someone pressed. Asks the system only if it hasn't been asked, then schedules what there is.
    func turnOn(for wanted: Context) async {
        device.setOptedIn(true, for: wanted.me.id)
        device.setDeclined(false, for: wanted.me.id)
        isOptedIn = true
        hasDeclined = false
        permission = await center.permission()
        if permission == .notAsked { permission = await center.requestPermission() }
        await replan(wanted)
    }

    /// Family's switch. Reminders stop now; cook-mode timers don't, and the system's permission stays as it is.
    func turnOff(for wanted: Context) async {
        device.setOptedIn(false, for: wanted.me.id)
        device.setDeclined(true, for: wanted.me.id)
        isOptedIn = false
        hasDeclined = true
        center.remove(await center.pendingIDs().filter(ReminderID.isReminder))
        await replan(wanted)
    }

    func decline(_ member: UUID) {
        device.setDeclined(true, for: member)
        hasDeclined = true
    }

    /// Sign-out, account deletion, or a household that's gone: nothing of this person's stays on the device, and nothing still
    /// in flight may put any back. The cached plan and the records go with `SyncService.clearCache`.
    static func clearDevice(center: ReminderCenter = .system, device: ReminderDevice = ReminderDevice(),
                            session: ReminderSession = .shared) {
        session.end()
        center.removeEverything()
        device.clear()
        ReminderRouter.shared.clear()
    }

    // MARK: - One run

    private func run(_ wanted: Context) async {
        guard let context else { return }
        let permission = await center.permission()
        // Before the read, so it sees them.
        await CheckInDelivery.send(device: device, client: client)
        let weeks = await fetchWeeks(settings: wanted.settings)
        guard !isStopped else { return }
        self.permission = permission
        hasDeclined = device.hasDeclined(wanted.me.id)
        isOptedIn = device.isOptedIn(wanted.me.id)
        if let weeks { saveSnapshot(weeks, in: context) }
        let snapshot = loadSnapshot(in: context)?.applying(device.checkIns)

        let pending = await center.pendingIDs().filter(ReminderID.isReminder)
        guard !isStopped else { return }
        forgetOtherPeople(than: wanted.me.id, in: context)
        fileAnswers(in: context)
        settleSent(pending: Set(pending), member: wanted.me.id, in: context)

        let plan = NotificationPlanner.plan(NotificationPlanner.Inputs(
            me: wanted.me, members: wanted.members, settings: wanted.settings, snapshot: snapshot,
            history: records(member: wanted.me.id, in: context).map(\.history), now: now()
        ))
        hasRemindersToOffer = !plan.isEmpty && snapshot?.weeks.contains(where: \.isApproved) == true

        guard permission == .on, isOptedIn else {
            center.remove(pending)
            forgetUnsent(keeping: [], member: wanted.me.id, in: context)
            await upload(member: wanted.me.id, in: context)
            return
        }

        let planned = Set(plan.map(\.id))
        center.remove(pending.filter { !planned.contains($0) })
        forgetUnsent(keeping: planned, member: wanted.me.id, in: context)
        var added: [String] = []
        let waiting = Set(pending)
        let known = Dictionary(records(member: wanted.me.id, in: context).map { ($0.key, $0.fireAt) },
                               uniquingKeysWith: { first, _ in first })
        for reminder in plan {
            guard !isStopped else { break }
            // Already in at that time: adding it again could send it twice if its moment is now.
            if waiting.contains(reminder.id), known[reminder.id] == reminder.fireAt { continue }
            guard await center.add(reminder, reminder.fireAt.timeIntervalSince(now())) else { continue }
            added.append(reminder.id)
            guard !isStopped else { break }
            noteScheduled(reminder, member: wanted.me.id, in: context)
        }
        // Stopped while adding: what just went in can't stay.
        if isStopped {
            center.remove(added)
            return
        }
        try? context.save()
        await upload(member: wanted.me.id, in: context)
    }

    /// This week and next by the household's calendar. Nil when they can't be read: the plan comes from the cache, offline
    /// included, until it's too old to trust.
    private func fetchWeeks(settings: HouseholdSettings) async -> [ReminderWeek]? {
        let calendar = DinnerPrompts.calendar(for: settings)
        let thisWeek = WeekMath.start(of: CalendarDay(now(), calendar: calendar), weekStart: settings.weekStart, calendar: calendar)
        return try? await client.weeks(householdID, thisWeek, thisWeek.adding(days: 7, calendar: calendar))
    }

    private func saveSnapshot(_ weeks: [ReminderWeek], in context: ModelContext) {
        guard let payload = try? JSONEncoder().encode(ReminderSnapshot(pulledAt: now(), weeks: weeks)) else { return }
        let household = householdID
        let cached = try? context.fetch(FetchDescriptor<CachedReminders>(predicate: #Predicate { $0.householdID == household })).first
        if let cached {
            cached.payload = payload
        } else {
            context.insert(CachedReminders(householdID: household, payload: payload))
        }
        try? context.save()
    }

    private func loadSnapshot(in context: ModelContext) -> ReminderSnapshot? {
        let household = householdID
        let cached = try? context.fetch(FetchDescriptor<CachedReminders>(predicate: #Predicate { $0.householdID == household })).first
        return cached.flatMap { try? JSONDecoder().decode(ReminderSnapshot.self, from: $0.payload) }
    }

    private func records(member: UUID, in context: ModelContext) -> [NotificationRecord] {
        let household = householdID
        let descriptor = FetchDescriptor<NotificationRecord>(predicate: #Predicate {
            $0.householdID == household && $0.memberID == member
        })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// A backstop for sign-out's wipe: what went out to someone else on this device is no part of this person's budget.
    private func forgetOtherPeople(than member: UUID, in context: ModelContext) {
        try? context.delete(model: NotificationRecord.self, where: #Predicate { $0.memberID != member })
    }

    /// Answers the delegate saved go on their records. One from a follow-up counts for what it followed.
    private func fileAnswers(in context: ModelContext) {
        let answers = device.answers
        guard !answers.isEmpty else { return }
        for answer in answers {
            let key = answer.id
            guard let record = try? context.fetch(FetchDescriptor<NotificationRecord>(predicate: #Predicate { $0.key == key })).first
            else { continue }
            // Answering means it arrived, whether or not this device had noticed yet.
            record.sentAt = record.sentAt ?? answer.at
            record.respondedAt = record.respondedAt ?? answer.at
            record.response = record.response ?? answer.response
            record.snoozedUntil = answer.snoozedUntil
            record.changed()
        }
        try? context.save()
        device.removeAnswers(answers)
    }

    /// A reminder whose time has passed and that isn't pending any more has gone out. iOS doesn't tell the app, and this is what
    /// budgets count. If someone turns notifications off between scheduling and firing it counts anyway: an overcount only means
    /// fewer reminders.
    private func settleSent(pending: Set<String>, member: UUID, in context: ModelContext) {
        let date = now()
        for record in records(member: member, in: context)
        where record.sentAt == nil && record.fireAt <= date && !pending.contains(record.key) {
            record.sentAt = record.fireAt
            record.changed()
        }
        try? context.save()
    }

    /// Reminders still ahead that the plan dropped: they were called off, so they don't count. A row already on the server keeps
    /// a null `sent_at`, which is what called off looks like there.
    private func forgetUnsent(keeping planned: Set<String>, member: UUID, in context: ModelContext) {
        for record in records(member: member, in: context) where record.sentAt == nil && !planned.contains(record.key) {
            context.delete(record)
        }
        try? context.save()
    }

    private func noteScheduled(_ reminder: PlannedReminder, member: UUID, in context: ModelContext) {
        if let record = records(member: member, in: context).first(where: { $0.key == reminder.id }) {
            guard record.fireAt != reminder.fireAt else { return }
            record.fireAt = reminder.fireAt
            record.changed()
        } else {
            context.insert(NotificationRecord(reminder: reminder, householdID: householdID, memberID: member))
        }
    }

    /// Best effort, and only ever on the way out of a run: the log waits for a connection, and nothing waits for the log. Rows too
    /// old to matter go whether or not they got through, so one the server keeps refusing can't stay forever.
    private func upload(member: UUID, in context: ModelContext) async {
        guard !isStopped else { return }
        let cutoff = now().addingTimeInterval(-Self.keptFor)
        for record in records(member: member, in: context) where record.fireAt < cutoff {
            context.delete(record)
        }
        try? context.save()

        let waiting = records(member: member, in: context).filter(\.needsUpload).prefix(Self.uploadBatch)
        guard !waiting.isEmpty else { return }
        let revisions = waiting.map { ($0.key, $0.revision) }
        guard (try? await client.record(householdID, waiting.map(\.logEntry))) != nil, !isStopped else { return }
        let current = records(member: member, in: context)
        for (key, revision) in revisions {
            if let record = current.first(where: { $0.key == key }), record.revision == revision {
                record.needsUpload = false
            }
        }
        try? context.save()
    }

    /// Long enough for the current week's budget and last week's stragglers.
    private static let keptFor: TimeInterval = 15 * 24 * 60 * 60
    private static let uploadBatch = 200
}
