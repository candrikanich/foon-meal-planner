import SwiftUI

/// "I want...": a dish from the library, a name, or a link, with an optional note and night. Pass the phone: a
/// profile nobody has claimed can ask too (docs/spec.md → Ideas tab).
struct IWantSheet: View {
    @Environment(IdeasStore.self) private var ideas
    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(WeekStore.self) private var week
    @Environment(\.dismiss) private var dismiss

    typealias Kind = NewRequest.Kind

    @State private var kind: Kind = .library
    @State private var mealID: UUID?
    @State private var title = ""
    @State private var link = ""
    @State private var note = ""
    @State private var hasNight = false
    @State private var night = Date.now
    @State private var from: UUID?
    @State private var search = ""

    /// You, and anyone without their own account (pass the phone).
    private var askers: [Member] {
        guard let me = household.me else { return [] }
        return DinnerPrompts.raters(home: household.visibleMembers, me: me.id)
    }

    private var meals: [LibraryMeal] {
        let inRotation = library.meals.filter(\.status.isInRotation).sorted { $0.name < $1.name }
        let typed = search.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? inRotation : inRotation.filter { $0.name.localizedStandardContains(typed) }
    }

    private var request: NewRequest? {
        guard let from = from ?? household.me?.id else { return nil }
        return NewRequest.build(kind: kind, from: from, mealID: mealID, title: title, link: link, note: note,
                                date: hasNight ? CalendarDay(night) : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("What", selection: $kind) {
                        Text("From our meals").tag(Kind.library)
                        Text("Name it").tag(Kind.name)
                        Text("A link").tag(Kind.link)
                    }
                    .pickerStyle(.segmented)
                }
                switch kind {
                case .library:
                    Section {
                        TextField("Search our meals", text: $search)
                        ForEach(meals.prefix(30)) { meal in
                            Button { mealID = meal.id } label: {
                                HStack {
                                    Text(meal.name).foregroundStyle(Palette.ink)
                                    Spacer()
                                    if mealID == meal.id { Image(systemName: "checkmark").foregroundStyle(Palette.paprika) }
                                }
                            }
                            .accessibilityAddTraits(mealID == meal.id ? .isSelected : [])
                        }
                    }
                case .name:
                    Section {
                        TextField("Crab legs, Grandma's pie...", text: $title)
                    } footer: {
                        Text("Up to \(NewRequest.titleLimit) characters.")
                    }
                case .link:
                    Section {
                        TextField("Recipe or video link", text: $link, prompt: Text(verbatim: "https://"))
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                        TextField("What is it? (optional)", text: $title)
                    } footer: {
                        Text("It shows under New finds until a planner adds it to the library.")
                    }
                }
                Section {
                    TextField("A note (optional)", text: $note, axis: .vertical).lineLimit(1...3)
                    Toggle("For a night", isOn: $hasNight)
                    if hasNight {
                        // From the same "today" the rest of This Week uses.
                        DatePicker("Night", selection: $night, in: week.todayDay.date()..., displayedComponents: .date)
                    }
                }
                if askers.count > 1 {
                    Section("Who wants it") {
                        Picker("From", selection: Binding(get: { from ?? household.me?.id }, set: { from = $0 })) {
                            ForEach(askers) { member in Text(member.firstName).tag(Optional(member.id)) }
                        }
                    }
                }
                if household.me == nil {
                    Section { Text("Loading your profile...").foregroundStyle(.secondary) }
                }
                if let message = ideas.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("I want...")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }.disabled(request == nil || ideas.isSending)
                }
            }
            .onAppear { ideas.clearError() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    private func send() {
        guard let request else { return }
        Task { if await ideas.make(request) { dismiss() } }
    }
}

#Preview("I want...") {
    let household = HouseholdStore.preview()
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    IWantSheet()
        .environment(household)
        .environment(IdeasStore(householdID: Household.sample.id, client: .preview()))
        .environment(library)
        .environment(WeekStore(householdID: Household.sample.id, client: .preview()))
        .task {
            await household.load()
            await library.load(members: Member.sampleFamily)
        }
}
