import SwiftUI

struct LibraryView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Library",
                systemImage: "book",
                description: Text("Your family's meals will live here.")
            )
            .navigationTitle("Library")
        }
    }
}

#Preview {
    LibraryView()
}
