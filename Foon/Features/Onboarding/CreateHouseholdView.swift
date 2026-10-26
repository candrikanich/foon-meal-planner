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

    private var canCreate: Bool {
        var owner = MemberDraft()
        owner.firstName = firstName
        return Household.validatedName(name) != nil && owner.validated() != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Invite code", text: $inviteCode, prompt: Text("SMITH-7KQ4-M9XP"))
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
