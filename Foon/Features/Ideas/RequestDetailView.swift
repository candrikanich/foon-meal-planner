import SwiftUI

/// One idea, and what happens to it. Planners: Plan it, Save to library, Not this week, Special occasion, Archive.
/// The person who asked (or entered it): Archive their own. There's no decline (docs/spec.md → Inbox rules).
struct RequestDetailView: View {
    @Environment(IdeasStore.self) private var ideas
    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(WeekStore.self) private var week
    @Environment(\.dismiss) private var dismiss
    @Environment(\.showTab) private var showTab
    let requestID: UUID
    @State private var planning: LibraryMeal?
    @State private var savingToLibrary = false
    /// A dish already made for this idea when linking it failed: retrying links it, never makes a second one.
    @State private var madeMealID: UUID?

    private var request: DinnerRequest? { ideas.requests.first { $0.id == requestID } }

    /// The current week, even while This Week shows next week: that's the week "not this week" means.
    private var thisWeek: CalendarDay {
        WeekMath.start(of: week.todayDay, weekStart: (household.household?.planningSettings ?? HouseholdSettings()).weekStart)
    }

    /// A dated idea still ahead, or a dish that would get priority this week.
    private func canWait(_ request: DinnerRequest) -> Bool {
        guard request.status == .open else { return false }
        if let date = request.targetDate, date >= week.todayDay { return true }
        return !RequestBoard.wanted([request], weekStart: thisWeek, today: week.todayDay, members: household.members)
            .isEmpty
    }

    private var canPlan: Bool {
        LibraryStore.canEdit(me: household.me, isOwner: household.household?.owner == household.userID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let request {
                    content(request)
                } else {
                    ContentUnavailableView("This idea is gone", systemImage: "lightbulb.slash",
                                           description: Text("Someone archived it."))
                }
            }
            .navigationTitle(request.map { RequestText.what($0, library: library) } ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $planning) { meal in
                PlanItSheet(meal: meal) { night in
                    await ideas.update(requestID, RequestUpdate(status: .planned, nightID: night))
                }
                .environment(\.showTab) { tab in
                    // Go to This Week from inside Plan it: this sheet goes too.
                    showTab(tab)
                    dismiss()
                }
            }
            .onAppear { ideas.clearError() }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 440)
        #endif
    }

    private func content(_ request: DinnerRequest) -> some View {
        List {
            Section {
                RequestRow(request: request)
                if let link = request.link {
                    Link(destination: link) { Label("Open the link", systemImage: "safari") }
                }
            }
            if canPlan {
                Section("What happens next") {
                    if let mealID = request.mealID {
                        if let meal = library.meal(mealID) {
                            Button("Plan it", systemImage: "calendar.badge.plus") { planning = meal }
                        } else {
                            // The library is still loading: never offer to make a dish this idea already has.
                            Label("Loading the dish...", systemImage: "hourglass").foregroundStyle(.secondary)
                        }
                    } else {
                        Button(savingToLibrary ? "Saving..." : "Save to library", systemImage: "book") {
                            Task { await saveToLibrary(request) }
                        }
                        .disabled(savingToLibrary)
                    }
                    if canWait(request) {
                        // Back to Someday, and no me-too priority until next week.
                        Button("Not this week", systemImage: "arrow.uturn.right") {
                            Task { await ideas.update(requestID, RequestUpdate(clearDate: true, skipWeek: thisWeek)) }
                        }
                    }
                    if request.status != .special {
                        Button("Save for a special occasion", systemImage: "gift") {
                            Task { await ideas.update(requestID, RequestUpdate(status: .special)) }
                        }
                    } else {
                        Button("Back to Someday", systemImage: "tray") {
                            Task { await ideas.update(requestID, RequestUpdate(status: .open, clearDate: true)) }
                        }
                    }
                    archive
                }
            } else if RequestBoard.canArchive(request, me: household.me, members: household.members) {
                Section { archive }
            }
            if let message = ideas.errorMessage ?? library.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .disabled(ideas.saving.contains(requestID))
    }

    private var archive: some View {
        Button("Archive", systemImage: "archivebox", role: .destructive) {
            Task { if await ideas.update(requestID, RequestUpdate(status: .archived)) { dismiss() } }
        }
    }

    /// Makes a library dish from the idea's name (and link), points the idea at it, then goes on to Plan it.
    private func saveToLibrary(_ request: DinnerRequest) async {
        guard !savingToLibrary else { return }
        savingToLibrary = true
        defer { savingToLibrary = false }
        library.clearError()
        let mealID: UUID
        if let madeMealID {
            mealID = madeMealID
        } else {
            var draft = MealDraft(newNamed: request.title ?? request.link?.host() ?? String(localized: "New dish"))
            draft.link = request.link?.absoluteString ?? ""
            guard let made = await library.create(draft) else { return }
            madeMealID = made
            mealID = made
        }
        guard await ideas.update(requestID, RequestUpdate(linkMealID: mealID)) else { return }
        madeMealID = nil
        planning = library.meal(mealID)
    }
}

#Preview("An idea") {
    let household = HouseholdStore.preview()
    let ideas = IdeasStore(householdID: Household.sample.id, client: .preview())
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    RequestDetailView(requestID: DinnerRequest.samples[0].id)
        .environment(household)
        .environment(ideas)
        .environment(library)
        .environment(WeekStore(householdID: Household.sample.id, client: .preview(started: true)))
        .task {
            await household.load()
            await ideas.load()
            await library.load(members: Member.sampleFamily)
        }
}

