import SwiftUI

struct FamilyView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Family",
                systemImage: "person.3",
                description: Text("Everyone at your table will show up here.")
            )
            .navigationTitle("Family")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Sign out") {
                        Task { await session.signOut() }
                    }
                }
            }
        }
    }
}

#Preview {
    FamilyView()
        .environment(SessionStore(auth: .preview()))
}
