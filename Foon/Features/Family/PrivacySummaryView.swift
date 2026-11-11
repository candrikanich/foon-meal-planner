import SwiftUI

/// What Foon keeps, in plain words. Every line here is true of the code today (docs/spec.md → Family tab), so a change to what
/// the app collects or sends changes this screen in the same PR. It isn't the privacy policy (#67), and it claims no law.
struct PrivacySummaryView: View {
    var body: some View {
        List {
            Section("What Foon keeps") {
                Text("Your household's name and emoji, first names, avatars, and who's a kid, a parent, or a planner.")
                Text("Allergies a parent adds, and each person's usual schedule.")
                Text("Your meals and meal photos, plans, lists, ideas, votes on dinner, ratings, comments, serving notes, and who cooked.")
                Text("Your household's time zone, so Foon knows when last night's dinner was.")
                Text("Your Apple sign-in: an account ID, an email, which can be Apple's private relay address, and your first name if Apple shares it.")
                Text("Who agreed and when, if a parent agrees to keep allergies or to invite a kid.")
                Text("Which reminders each person's device sent and whether they answered: the kind, the night, and the time, never the words.")
                Text("If your household subscribes: Apple's subscription status for it, which plan, when it ends, and Apple's original transaction ID. Apple holds your payment details; Foon never sees them.")
                Text("Receipt lines someone in the family corrected, and the item each one is, so the next receipt reads right.")
                Text("When someone finishes a shopping trip with something bought, that your household finished one and when, never what was bought, where, or by whom. Foon counts trips across many families to see how it's used.")
                Text("When a planner adds a dish from a photo, PDF, or post on a device that can't run Apple's on-device AI, its recipe lines, held briefly so a planner's device in your family that can will tidy them up. They go once that's done, or after 3 days at most; the tidied recipe is kept for 30 days.")
                Text("Whether you turned on the weekly plan email or founding-family updates, and when you agreed. Only you see it. The setting goes with your account; the record that you agreed, like your agreement to the Terms and Privacy Policy, is kept as proof.")
                Text("Foon doesn't ask for birthdays, phone numbers, or your location.")
            }

            Section("Email from Foon") {
                Text("Foon emails adults only, never kids. Emails about your account go to the email Apple gives for your account (which can be Apple's private relay address). Our email provider, Resend, sends them.")
                Text("About your account: a welcome when you create a household; if you own it, notices when its subscription starts, renews, changes plan, can't be charged, has renewal turned off or on, is refunded, or ends; and a receipt when you delete your account or household.")
                Text("Only if you turn them on, in Family under Email: the weekly plan email (the week's dinners when it's approved, never allergies or who's home) and founding-family updates (news and offers about Foon, now and then). Both start off.")
                Text("If you email an invite to another adult, Foon uses the address you type only to send that one invite. Foon doesn't keep it; Resend keeps its own record of the send, as for every email.")
                Text("Foon keeps no copy of these emails. A record that one was queued or sent, its kind and date and never your address, is deleted after 30 days. Resend keeps its own record of each email it sends.")
            }

            Section("What stays on this device") {
                Text("A copy of this week's and next week's plan and your lists, so they work offline and reminders can go out. It's erased when you sign out or your household is gone.")
                Text("Photos and PDFs you share to Foon. They're read here and then deleted. Only the text you keep leaves this device, and the recipe lines of a dish you add, if this device can't tidy them up itself.")
                Text("If a planner turns on Spot busy evenings, Foon reads the times of this device's calendar events to suggest rushed nights. It never saves or sends them.")
                Text("Receipt photos. They're read here and never kept or uploaded.")
                Text("If you turn on Dinner memories, Foon shows photos from this device's library taken around dinner on nights your family logged. It never saves or uploads them.")
            }

            Section("What leaves this device") {
                Text("What you add goes to Foon's servers, so your family sees it too. Meal photos lose their location and camera details first.")
                Text("When you import a recipe from a link, Foon's server opens that page to read it.")
                Text("AI runs on your family's own devices, with Apple's on-device model, and a device that can run it sends nothing for AI. One that can't sends a dish's recipe lines through Foon's servers to a planner's device in your family that can, and only when a planner adds the dish.")
                Text("The app has no ads and no tracking, and allergies are never sent anywhere for AI.")
            }

            Section("Who sees what") {
                Text("Everyone in your household sees the family, allergies, schedules, the plan, lists, ideas, votes on dinner, ratings and comments, and who cooked. Planners can see the reminder log and comments a planner hid, and parents can see their kids'. Everyone else sees only their own reminders.")
                Text("Other households can't see any of it.")
                Text("Parents manage people and change allergies. Planners build the week. Planners and parents can export the household. Only the owner can delete it.")
            }

            Section {
                Text("Parents can change or remove someone's allergies on their profile.")
                Text("A parent can turn allergy alerts off in Family. That erases every allergy recorded for your household.")
                Text("Deleting the household removes it from Foon for everyone, right away, and the app can't bring it back.")
                Text("Plan activity, votes on dinner, and the reminder log are deleted after eight weeks.")
                Text("Anyone removed from the family becomes \"Former member\" after 12 months, and their ratings stay as anonymous history.")
                Text("Invites are deleted 30 days after they're used, cancelled, or expire.")
                Text("Finished shopping trips are deleted after 13 months.")
                Text("Turn the weekly plan email or founding-family updates off in Family under Email, or with the link in any of them.")
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
