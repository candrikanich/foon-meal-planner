import SwiftUI

struct ListsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Lists",
                systemImage: "checklist",
                description: Text("Shopping lists will show up here.")
            )
            .navigationTitle("Lists")
        }
    }
}

#Preview {
    ListsView()
}
