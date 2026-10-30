import SwiftUI

/// Season templates (docs/spec.md → Saved schedules): save everyone's usual nights home under a name, and switch
/// between them when the season changes. Planners only.
struct AttendanceTemplatesView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var naming = false
    @State private var name = ""
    @State private var switching: AttendanceTemplate?

    /// Switching replaces everyone's usual nights, so say so if they aren't saved anywhere.
    private var currentIsSaved: Bool {
        store.attendanceTemplates.contains { $0.isInUse(by: store.members) }
    }

    var body: some View {
        List {
            Section {
                if store.attendanceTemplates.isEmpty {
                    Text("Nothing saved yet. Set up everyone's usual nights for this season, then save them here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.attendanceTemplates) { template in
                    row(template)
                }
            } footer: {
                Text("Switching changes the usual nights for weeks you start from now on. Weeks already started stay as they are.")
            }

            Section {
                Button("Save today's schedule", systemImage: "square.and.arrow.down") {
                    name = ""
                    naming = true
                }
                .tint(Palette.paprika)
            } footer: {
                if let message = store.errorMessage {
                    Text(message).foregroundStyle(.red)
                } else {
                    Text("Saves everyone's usual nights home as they are now. Using a name again replaces that one.")
                }
            }
        }
        .navigationTitle("Saved schedules")
        .task {
            store.clearError()
            await store.loadTemplates()
        }
        .refreshable { await store.loadTemplates() }
        .alert("Name this schedule", isPresented: $naming) {
            TextField("School year", text: $name)
            Button("Save") {
                let name = name
                Task { _ = await store.saveTemplate(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Switch to \(switching?.name ?? "")?", isPresented: Binding(
                get: { switching != nil }, set: { if !$0 { switching = nil } }
            ), titleVisibility: .visible, presenting: switching
        ) { template in
            Button("Switch schedules") {
                Task { _ = await store.applyTemplate(template) }
            }
        } message: { _ in
            if currentIsSaved {
                Text("Everyone's usual nights home change to this schedule.")
            } else {
                Text("Everyone's usual nights home change to this schedule. Today's isn't saved, so save it first if you'll want it back.")
            }
        }
    }

    private func row(_ template: AttendanceTemplate) -> some View {
        let inUse = template.isInUse(by: store.members)
        return HStack {
            Button {
                switching = template
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                        Text(template.summary(members: store.visibleMembers))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if inUse {
                        Image(systemName: "checkmark").foregroundStyle(Palette.herb).accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(inUse)
            .accessibilityValue(inUse ? String(localized: "In use") : "")
            .accessibilityHint(inUse ? "" : String(localized: "Switches everyone to this schedule"))

            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { _ = await store.deleteTemplate(template) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Delete \(template.name)"))
        }
    }
}

#Preview("Parent") {
    let store = HouseholdStore.preview()
    NavigationStack { AttendanceTemplatesView() }
        .environment(store)
        .task { await store.load() }
}
