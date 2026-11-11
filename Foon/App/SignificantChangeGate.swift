#if os(iOS) && canImport(DeclaredAgeRange) && canImport(PermissionKit)
// AgeRangeService and its RegulatoryFeature aren't marked Sendable yet.
@preconcurrency import DeclaredAgeRange
import PermissionKit
import StoreKit
#endif
import SwiftUI

/// The `significantChange()` hook (#88). When Foon ships a change listed in `SignificantChange.all`, and Apple says the
/// person's region requires it (`requiredRegulatoryFeatures`), a minor needs a parent's OK through PermissionKit before
/// going on, and an adult sees Apple's acknowledgment. The list is empty until a change qualifies, so today it asks
/// nothing and calls none of Apple's APIs. iOS only: the acknowledgment sheet doesn't exist on the Mac.
struct SignificantChangeGate: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS) && canImport(DeclaredAgeRange) && canImport(PermissionKit)
        if #available(iOS 26.4, *) {
            content.modifier(SignificantChangeFlow())
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(iOS) && canImport(DeclaredAgeRange) && canImport(PermissionKit)
@available(iOS 26.4, *)
private struct SignificantChangeFlow: ViewModifier {
    @Environment(\.requestAgeRange) private var requestAgeRange
    @Environment(\.showSignificantUpdateAcknowledgment) private var showAcknowledgment
    /// What a minor's parent is asked about; while it's set, Foon waits for their OK.
    @State private var askingParent: ParentQuestion?

    struct ParentQuestion: Identifiable {
        let summary: String
        var id: String { summary }
    }

    func body(content: Content) -> some View {
        content
            .task { await check() }
            .fullScreenCover(item: $askingParent) { question in
                ParentApprovalView(summary: question.summary)
                    .interactiveDismissDisabled()
                    .task { await waitForParent() }
            }
    }

    private func pending() async -> [SignificantChange] {
        guard !SignificantChange.all.isEmpty else { return [] }
        var original: String?
        if let transaction = try? await AppTransaction.shared, case .verified(let app) = transaction {
            original = app.originalAppVersion
        }
        return SignificantChange.pending(SignificantChange.all, handled: SignificantChangeLedger().handled,
                                         originalAppVersion: original)
    }

    private func check() async {
        let changes = await pending()
        guard !changes.isEmpty, let law = await Self.whatTheLawAsks() else { return }
        let parentsMustApprove = law.parents
        let adultsAcknowledge = law.adults
        guard parentsMustApprove || adultsAcknowledge else {
            // Nothing the law asks for where they are.
            SignificantChangeLedger().markHandled(changes)
            return
        }
        // Declined or unavailable: nothing is decided, so the next launch asks again.
        guard let response = try? await requestAgeRange(ageGates: 18, nil, nil),
              case .sharing(let range) = response else { return }
        let summary = SignificantChange.summary(of: changes)
        if let upper = range.upperBound, upper < 18 {
            guard parentsMustApprove else { return SignificantChangeLedger().markHandled(changes) }
            askingParent = ParentQuestion(summary: summary)
        } else if let lower = range.lowerBound, lower >= 18 {
            guard adultsAcknowledge else { return SignificantChangeLedger().markHandled(changes) }
            do {
                try await showAcknowledgment(updateDescription: summary)
                SignificantChangeLedger().markHandled(changes)
            } catch {
                // Not acknowledged this time; the next launch shows it again.
            }
        }
    }

    /// Whether a parent must approve and whether an adult must acknowledge, where this person is. Read off the main
    /// actor and returned as plain Bools, since Apple's types aren't Sendable.
    private nonisolated static func whatTheLawAsks() async -> (parents: Bool, adults: Bool)? {
        guard let features = try? await AgeRangeService.shared.requiredRegulatoryFeatures else { return nil }
        return (features.contains(.significantAppChangeRequiresParentalConsent),
                features.contains(.significantAppChangeRequiresAdultNotification))
    }

    /// A parent's yes lets them back in; a no keeps Foon waiting, as the law asks.
    private func waitForParent() async {
        for await response in AskCenter.shared.responses(for: SignificantAppUpdateTopic.self) {
            guard response.choice.answer == .approval else { continue }
            SignificantChangeLedger().markHandled(SignificantChange.all)
            askingParent = nil
            return
        }
    }
}

@available(iOS 26.4, *)
private struct ParentApprovalView: View {
    @Environment(SessionStore.self) private var session
    @State private var deletingAccount = false
    let summary: String

    var body: some View {
        ContentUnavailableView {
            Label("Foon has changed", systemImage: "person.2.badge.key")
        } description: {
            VStack(spacing: 12) {
                Text(verbatim: summary)
                Text("A parent needs to OK this before you keep using Foon.")
            }
        } actions: {
            PermissionButton(question: PermissionQuestion(
                significantAppUpdateTopic: SignificantAppUpdateTopic(description: summary))) {
                Text("Ask a parent")
            }
            .accessibilityHint(Text("Sends the question to your parent's device"))
            .buttonStyle(.borderedProminent)
            // Waiting must never trap them: like the held screen, they can always leave, and delete their account.
            Button("Sign out") { Task { await session.signOut() } }
            Button("Delete my account", role: .destructive) { deletingAccount = true }
        }
        .sheet(isPresented: $deletingAccount) { DeleteAccountView() }
    }
}

#Preview("Waiting for a parent") {
    if #available(iOS 26.4, *) {
        ParentApprovalView(summary: "Foon now lets families share photos of dinner.")
            .environment(SessionStore(auth: .preview()))
            .environment(HouseholdStore(userID: .previewUser, client: .preview(household: nil)))
    }
}
#endif
