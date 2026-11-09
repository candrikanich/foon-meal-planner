import SwiftUI

/// A kid's own device while a hold has them signed out (#277): a parent needs to agree to the kids' wording again.
/// Nothing was deleted, and once a parent agrees by email the account is linked back, so Check again brings them in.
struct HeldAccessView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    let hold: AccessHold

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Waiting for a parent", systemImage: "hourglass")
            } description: {
                Text("""
                Hi \(hold.firstName). Foon changed what parents agree to for kids, so a parent in \
                \(hold.householdName) needs to agree again before you can use Foon. Nothing was deleted: your profile \
                and everything you added are still there.
                """)
            } actions: {
                Button("Check again") { Task { await store.load() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isLoading)
                Button("Sign out") { Task { await session.signOut() } }
            }
        }
        // A parent agrees in their email, outside Foon: look again on coming back.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.load() } }
        }
    }
}

#Preview {
    var client = HouseholdClient.preview(household: nil)
    client.accessHold = { .preview }
    let store = HouseholdStore(userID: .previewUser, client: client)
    return HeldAccessView(hold: .preview)
        .environment(store)
        .environment(SessionStore(auth: .preview()))
}
