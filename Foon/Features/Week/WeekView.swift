import SwiftUI

struct WeekView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "This Week",
                systemImage: "calendar",
                description: Text("Your week of dinners will show up here.")
            )
            .navigationTitle("This Week")
        }
    }
}

#Preview {
    WeekView()
}
