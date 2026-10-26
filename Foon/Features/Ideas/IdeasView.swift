import SwiftUI

struct IdeasView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Ideas",
                systemImage: "lightbulb",
                description: Text("Dinner ideas from the family will show up here.")
            )
            .navigationTitle("Ideas")
        }
    }
}

#Preview {
    IdeasView()
}
