import SwiftUI

/// What Foon keeps, in plain words. Every line here is true of the code today (docs/spec.md → Family tab), so a change to what
/// the app collects or sends changes this screen in the same PR. It isn't the privacy policy (#67), and it claims no law.
struct PrivacySummaryView: View {
    var body: some View {
        List {
            Section("What Foon keeps") {
                Text("Your household's name and emoji, first names, avatars, and who's a kid, a parent, or a planner.")
                Text("Allergies a parent adds, and each person's usual schedule.")
                Text("Your meals and meal photos, plans, lists, ideas, ratings, comments, serving notes, and who cooked.")
                Text("Your household's time zone, so Foon knows when last night's dinner was.")
                Text("Your Apple sign-in: an account ID, an email, which can be Apple's private relay address, and your first name if Apple shares it.")
                Text("Who agreed and when, if a parent agrees to keep allergies or to invite a kid.")
                Text("Foon doesn't ask for birthdays, phone numbers, or your location.")
            }

            Section("What stays on this device") {
                Text("A copy of this week's plan and your lists, so they work offline. It's erased when you sign out or your household is gone.")
                Text("Photos and PDFs you share to Foon. They're read here and then deleted, and only the text you keep is saved.")
            }

            Section("What leaves this device") {
                Text("What you add goes to Foon's servers, so your family sees it too. Meal photos lose their location and camera details first.")
                Text("When you import a recipe from a link, Foon's server opens that page to read it.")
                Text("The app has no ads and no tracking, and allergies are never sent anywhere for AI.")
            }

            Section("Who sees what") {
                Text("Everyone in your household sees the family, allergies, schedules, the plan, lists, ideas, ratings and comments, and who cooked.")
                Text("Other households can't see any of it.")
                Text("Parents manage people and change allergies. Planners build the week and can export the household. Only the owner can delete it.")
            }

            Section {
                Text("Parents can change or remove someone's allergies on their profile.")
                Text("Deleting the household removes it from Foon for everyone, right away, and the app can't bring it back.")
                Text("Plan activity is deleted after eight weeks.")
                Text("A kid removed from the family becomes \"Former member\" after 12 months, and their ratings stay as anonymous history.")
            } header: {
                Text("Changing your mind")
            } footer: {
                Text("A plain summary, not the privacy policy. What you can export or delete is back on Family, under Your data.")
            }
        }
        .navigationTitle("What Foon keeps")
    }
}

#Preview {
    NavigationStack { PrivacySummaryView() }
}
