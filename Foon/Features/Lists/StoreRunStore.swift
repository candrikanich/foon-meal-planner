import Foundation
import Observation
import Supabase
import SwiftUI

/// The household's store run, for the Lists tab and store mode. Needs a connection: a run is about the next 10 minutes,
/// so a stale one isn't worth showing.
@Observable @MainActor
final class StoreRunStore {
    private(set) var run: StoreRun?
    private(set) var isStarting = false
    private(set) var errorMessage: String?

    let householdID: UUID
    private let client: StoreRunClient

    init(householdID: UUID, client: StoreRunClient, run: StoreRun? = nil) {
        self.householdID = householdID
        self.client = client
        self.run = run
    }

    func openRun(at now: Date) -> StoreRun? {
        run.flatMap { $0.isOpen(at: now) ? $0 : nil }
    }

    /// Quiet when it can't load: the button still works, and the server says if one is already open.
    func load() async {
        guard let latest = try? await client.latest(householdID) else { return }
        run = latest
    }

    func start() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            run = try await client.start(householdID)
            errorMessage = nil
        } catch {
            errorMessage = (error as? PostgrestError)?.code == "42501"
                ? String(localized: "Only an adult in the family can say they're heading to the store.")
                : String(localized: "Couldn't tell the family. Check your connection and try again.")
        }
    }
}

extension EnvironmentValues {
    /// Set at the app root to the live client; previews use their own.
    @Entry var storeRunClient = StoreRunClient.unconfigured
}

/// "Heading to the store" in Lists: a button for adults, and while a run is open, who's shopping and how long's left.
/// The Section stays a direct child of the List (so its footer shows); the times inside it follow the clock.
struct StoreRunSection: View {
    let store: StoreRunStore
    let me: Member?
    let members: [Member]

    private var schedule: StoreRunSchedule { StoreRunSchedule(endsAt: store.run?.endsAt) }

    var body: some View {
        Section {
            TimelineView(schedule) { context in
                if let run = store.openRun(at: context.date) {
                    Label(StoreRunText.running(run, members: members, me: me, now: context.date), systemImage: "cart.fill")
                        .foregroundStyle(Palette.paprika)
                } else if StoreRun.canStart(me) {
                    Button {
                        Task { await store.start() }
                    } label: {
                        Label("Heading to the store", systemImage: "car")
                    }
                    .disabled(store.isStarting)
                    .accessibilityHint("Tells the family to add anything in the next 10 minutes")
                }
            }
            if let message = store.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
        } footer: {
            TimelineView(schedule) { context in
                if store.openRun(at: context.date) != nil {
                    Text("What's added now is marked in store mode.")
                } else if StoreRun.canStart(me) {
                    Text("Tells the family you're shopping, so they can add anything in the next 10 minutes.")
                }
            }
        }
    }
}

/// Every 30 seconds for the minutes left, and exactly when the run ends, so the button comes back on the dot.
struct StoreRunSchedule: TimelineSchedule {
    let endsAt: Date?

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = start
        return AnyIterator {
            let current = next
            let periodic = current.addingTimeInterval(30)
            if let endsAt, current < endsAt, endsAt < periodic {
                next = endsAt
            } else {
                next = periodic
            }
            return current
        }
    }
}

/// The words, kept apart so they can be tested.
enum StoreRunText {
    static func running(_ run: StoreRun, members: [Member], me: Member?, now: Date) -> String {
        let minutes = run.minutesLeft(at: now)
        if let starter = run.startedBy, starter == me?.id {
            return minutes == 1
                ? String(localized: "You're at the store: 1 min left")
                : String(localized: "You're at the store: \(minutes) min left")
        }
        guard let name = members.first(where: { $0.id == run.startedBy })?.firstName else {
            return minutes == 1
                ? String(localized: "Store run: 1 min left")
                : String(localized: "Store run: \(minutes) min left")
        }
        return minutes == 1
            ? String(localized: "\(name)'s at the store: 1 min left", comment: "A family member is shopping now")
            : String(localized: "\(name)'s at the store: \(minutes) min left", comment: "A family member is shopping now")
    }
}

#Preview("Not started") {
    List {
        StoreRunSection(store: StoreRunStore(householdID: Household.sample.id, client: .preview),
                        me: Member.sampleFamily.first, members: Member.sampleFamily)
    }
}

#Preview("Running") {
    List {
        StoreRunSection(store: StoreRunStore(householdID: Household.sample.id, client: .preview,
                                             run: StoreRun(id: UUID(), startedBy: Member.sampleFamily.first?.id,
                                                           startedAt: .now, endsAt: .now.addingTimeInterval(480))),
                        me: Member.sampleFamily.last, members: Member.sampleFamily)
    }
}
