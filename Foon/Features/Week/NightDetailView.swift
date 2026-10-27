import SwiftUI

/// One night in full: what's for dinner, who's home, effort, and the lock. Planners change it; everyone sees it.
struct NightDetailView: View {
    @Environment(WeekStore.self) private var week
    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let nightID: UUID
    let canPlan: Bool

    private static let efforts: [NightEffort] = [.normal, .rushed, .full, .event]

    private var night: WeekNight? { week.week?.nights.first { $0.id == nightID } }

    var body: some View {
        NavigationStack {
            if let night {
                form(night)
                    .navigationTitle(DayCardText.dayLabel(for: night.date, today: week.todayDay))
            } else {
                ContentUnavailableView("Night not found", systemImage: "calendar")
            }
        }
    }

    private func form(_ night: WeekNight) -> some View {
        Form {
            Section {
                dinner(night)
                if let time = night.dinnerTime {
                    LabeledContent("Dinner at", value: String(time.prefix(5)))
                }
            } header: {
                Text(DayCardText.dateLabel(for: night.date))
            }

            Section("Effort") {
                if canPlan {
                    Picker("Effort", selection: Binding(
                        get: { night.effort },
                        set: { effort in Task { await week.setEffort(effort, nightID: night.id) } }
                    )) {
                        ForEach(Self.efforts, id: \.self) { Text(DayCardText.effortLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text(DayCardText.effortLabel(night.effort))
                }
            }

            Section("Who's home") {
                ForEach(household.visibleMembers.filter { night.attendance[$0.id] != nil }) { member in
                    let home = night.attendance[member.id] ?? false
                    if canPlan {
                        Toggle(isOn: Binding(
                            get: { home },
                            set: { _ in Task { await week.toggleAttendance(nightID: night.id, memberID: member.id) } }
                        )) {
                            Label { Text(member.firstName) } icon: { MemberAvatar(member: member, size: 28) }
                        }
                    } else {
                        LabeledContent {
                            Text(home ? "Home" : "Out")
                        } label: {
                            Label { Text(member.firstName) } icon: { MemberAvatar(member: member, size: 28) }
                        }
                    }
                }
            }

            if canPlan {
                Section {
                    Toggle("Lock this night", isOn: Binding(
                        get: { night.locked },
                        set: { _ in Task { await week.toggleLock(nightID: night.id) } }
                    ))
                } footer: {
                    Text("Build my week and shuffles leave locked nights as they are.")
                }
            }

            if let message = week.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func dinner(_ night: WeekNight) -> some View {
        if let mealID = night.mealID, let name = night.mealName {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.foonTitle)
                if let sides = DayCardText.sidesLabel(library.meal(mealID).map(library.sideNames(for:)) ?? []) {
                    Text(sides).font(.foonCaption).foregroundStyle(.secondary)
                }
            }
        } else if let pick = night.quickPick {
            Text(DayCardText.quickPickLabel(pick)).font(.foonTitle)
        } else {
            Text("Nothing planned yet").foregroundStyle(.secondary)
        }
    }
}
