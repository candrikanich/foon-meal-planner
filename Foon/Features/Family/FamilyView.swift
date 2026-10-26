import SwiftUI

struct FamilyView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Family",
                systemImage: "person.3",
                description: Text("Everyone at your table will show up here.")
            )
            .navigationTitle("Family")
        }
    }
}

#Preview {
    FamilyView()
}
