import SwiftUI

/// Dinner jobs (docs/spec.md → Dinner jobs): which helper jobs the household uses, and who takes turns. Off until a planner
/// picks one. Planners only; each toggle changes only itself on the server, so two planners can't undo each other.
struct DinnerJobsView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var isSaving = false

    private var settings: DinnerJobSettings { store.household?.planningSettings.dinnerJobs ?? DinnerJobSettings() }
    private var eligible: [Member] { store.visibleMembers.filter { !$0.eatsSeparately } }

    var body: some View {
        Form {
            Section {
                ForEach(DinnerJob.allCases, id: \.self) { job in
                    Toggle(job.title, isOn: Binding(
                        get: { settings.jobs.contains(job) },
                        set: { isOn in save { await store.setDinnerJob(job, isOn: isOn) } }
                    ))
                }
            } header: {
                Text("Which jobs")
            } footer: {
                Text("Foon takes turns among whoever's home each night, and whoever's cooking gets the night off. Nobody checks anything off, and Foon doesn't keep score.")
            }

            if !settings.jobs.isEmpty {
                Section {
                    ForEach(eligible) { member in
                        Toggle(isOn: Binding(
                            get: { !settings.leftOut.contains(member.id) },
                            set: { isIn in save { await store.setDinnerJobPerson(member.id, isIn: isIn) } }
                        )) {
                            Label { Text(member.firstName) } icon: { MemberAvatar(member: member, size: 28) }
                        }
                    }
                } header: {
                    Text("Who takes turns")
                } footer: {
                    if store.visibleMembers.contains(where: \.eatsSeparately) {
                        Text("Someone who eats separately isn't in the rotation.")
                    }
                }
            }

            if let message = store.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .disabled(isSaving)
        .navigationTitle("Dinner jobs")
        .onAppear { store.clearError() }
    }

    private func save(_ write: @escaping @MainActor () async -> Bool) {
        isSaving = true
        Task {
            _ = await write()
            isSaving = false
        }
    }
}

#Preview("Off") {
    let store = HouseholdStore.preview()
    NavigationStack { DinnerJobsView() }
        .environment(store)
        .task { await store.load() }
}

#Preview("Two jobs") {
    var settings = HouseholdSettings()
    settings.dinnerJobs = DinnerJobSettings(jobs: [.setTable, .dishes], leftOut: [Member.sampleFamily[2].id])
    var household = Household.sample
    household.settings = settings
    let store = HouseholdStore.preview(household: household)
    return NavigationStack { DinnerJobsView() }
        .environment(store)
        .task { await store.load() }
}
