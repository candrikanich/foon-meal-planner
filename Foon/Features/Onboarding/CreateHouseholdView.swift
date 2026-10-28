import SwiftUI

struct CreateHouseholdView: View {
    static let emojiChoices = ["🏡", "🌮", "🍝", "🍕", "🥘", "🍲", "🌻", "⭐️"]

    @Environment(HouseholdStore.self) private var store
    @Environment(SessionStore.self) private var session
    @State private var name = ""
    @State private var emoji = "🏡"
    @State private var firstName = ""
    @State private var isSaving = false
    @State private var inviteCode = ""
    @State private var confirmingSample = false

    private var canCreate: Bool {
        var owner = MemberDraft()
        owner.firstName = firstName
        return Household.validatedName(name) != nil && owner.validated() != nil
    }

    private func loadSample() {
        Task {
            isSaving = true
            await store.createHousehold(name: String(localized: "The Sample Family"), emoji: "🧪",
                                        firstName: firstName.isEmpty ? String(localized: "You") : firstName,
                                        sample: true)
            isSaving = false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        confirmingSample = true
                    } label: {
                        Label("Load a sample family", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                    .disabled(isSaving)
                    // v1 has one household per person and no way to delete one yet, so the demo would be theirs to
                    // keep: say so before it's made.
                    .confirmationDialog("Use the sample family as your household?", isPresented: $confirmingSample,
                                        titleVisibility: .visible) {
                        Button("Load the sample family") { loadSample() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("It becomes your household. You can rename it and change the family, but you can't start a new one later.")
                    }
                } footer: {
                    Text("A demo family with dinners and a planned week, to look around first.")
                }

                Section {
                    TextField("Invite code", text: $inviteCode, prompt: Text(verbatim: "SMITH-7KQ4-M9XP"))
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button {
                        Task {
                            isSaving = true
                            await store.redeem(inviteCode)
                            if store.household != nil { session.clearPendingInvite() }
                            isSaving = false
                        }
                    } label: {
                        Text("Join family").frame(maxWidth: .infinity)
                    }
                    .disabled(isSaving || !InviteCode.isComplete(inviteCode))
                } header: {
                    Text("Joining a family?")
                } footer: {
                    Text("Enter the code from your invite. Otherwise, start your own household below.")
                }

                Section {
                    TextField("Household name", text: $name, prompt: Text("The Smiths"))
                        .textContentType(.familyName)
                } header: {
                    Text("Your household")
                } footer: {
                    Text("A last name or a nickname. Everyone you invite will see it.")
                }

                Section("Pick an emoji") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                        ForEach(Self.emojiChoices, id: \.self) { choice in
                            Button {
                                emoji = choice
                            } label: {
                                Text(choice)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(emoji == choice ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Household emoji \(choice)")
                            .accessibilityAddTraits(emoji == choice ? .isSelected : [])
                        }
                    }
                }

                Section("You") {
                    TextField("Your first name", text: $firstName)
                        .textContentType(.givenName)
                }

                Section {
                    Button {
                        Task {
                            isSaving = true
                            await store.createHousehold(name: name, emoji: emoji, firstName: firstName)
                            isSaving = false
                        }
                    } label: {
                        Text("Create household").frame(maxWidth: .infinity)
                    }
                    .disabled(isSaving || !canCreate)
                } footer: {
                    if let message = store.errorMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Welcome to Foon")
            .onChange(of: session.pendingInviteCode) { _, code in
                if let code { inviteCode = code }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign out") {
                        Task { await session.signOut() }
                    }
                }
            }
            .onAppear {
                store.clearError()
                if inviteCode.isEmpty, let pending = session.pendingInviteCode {
                    inviteCode = pending
                }
                if firstName.isEmpty, let given = session.appleGivenName {
                    firstName = given
                }
            }
        }
    }
}

#Preview {
    CreateHouseholdView()
        .environment(HouseholdStore.preview(household: nil))
        .environment(SessionStore(auth: .preview()))
}
