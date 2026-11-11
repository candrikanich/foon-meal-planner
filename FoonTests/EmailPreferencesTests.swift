import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

struct EmailOptInWordingTests {
    @Test func eachEmailHasItsRegisteredWording() {
        #expect(EmailOptIn.weeklyPlan.textVersion == "weekly-plan-email-v1")
        #expect(EmailOptIn.foundingUpdates.textVersion == "founding-updates-v1")
        #expect(EmailOptIn.weeklyPlan.rawValue == "weekly_plan", "the kind set_email_preference takes")
        #expect(EmailOptIn.foundingUpdates.rawValue == "founding_updates")
    }

    @Test func theWordingSaysWhereItGoesAndHowToStop() {
        for email in EmailOptIn.allCases {
            #expect(email.statement.contains("the email Apple gave for your account"))
            #expect(email.statement.contains("link in any of"))
        }
        #expect(EmailOptIn.weeklyPlan.statement.contains("never includes allergies"))
        #expect(EmailOptIn.foundingUpdates.statement.contains("offers"), "it's marketing, and says so")
    }

    @Test func preferencesDecodeFromTheServer() throws {
        let json = Data(#"{"weekly_plan": true, "founding_updates": false, "can_opt_in": true, "available": true}"#.utf8)
        let preferences = try JSONDecoder().decode(EmailPreferences.self, from: json)
        #expect(preferences == EmailPreferences(weeklyPlan: true, foundingUpdates: false, canOptIn: true, available: true))
        #expect(preferences.isOn(.weeklyPlan))
        #expect(!preferences.isOn(.foundingUpdates))
    }

    @Test func shownOnlyWhileEmailIsOnForAnAdultOrSomethingIsOn() {
        #expect(EmailPreferences(canOptIn: true, available: true).isShown)
        #expect(!EmailPreferences(canOptIn: true, available: false).isShown, "nothing to turn on before Foon sends email")
        #expect(!EmailPreferences(canOptIn: false, available: true).isShown, "kids never see it")
        #expect(EmailPreferences(foundingUpdates: true, canOptIn: false, available: false).isShown,
                "something on can always be turned off")
    }
}

@MainActor
struct EmailPreferencesModelTests {
    nonisolated private static let refused = PostgrestError(code: "42501", message: "adults only")
    nonisolated private static let emailOff = PostgrestError(code: "55000", message: "email off")

    private struct Call: Equatable {
        let email: EmailOptIn
        let isOn: Bool
        let wording: String?
    }

    private final class Calls: Sendable {
        private let calls = Mutex<[Call]>([])
        var all: [Call] { calls.withLock { $0 } }
        func add(_ call: Call) { calls.withLock { $0.append(call) } }
    }

    nonisolated private static let ready = EmailPreferences(canOptIn: true, available: true)

    private func model(load: @escaping @Sendable () throws -> EmailPreferences = { ready },
                       set: (@Sendable () throws -> Void)? = nil, calls: Calls = Calls()) -> EmailPreferencesModel {
        var client = HouseholdClient.preview()
        client.emailPreferences = { try load() }
        client.setEmailPreference = { email, isOn, wording, _ in
            try set?()
            calls.add(Call(email: email, isOn: isOn, wording: wording))
            var next = Self.ready
            if email == .weeklyPlan { next.weeklyPlan = isOn } else { next.foundingUpdates = isOn }
            return next
        }
        return EmailPreferencesModel(client: client)
    }

    @Test func loadsTheCallersOwnSwitches() async {
        let model = model()
        await model.load()
        #expect(model.phase == .ready(Self.ready))
        #expect(model.isShown)
    }

    @Test func aFailedLoadShowsNothing() async {
        let model = model(load: { throw URLError(.notConnectedToInternet) })
        await model.load()
        #expect(model.phase == .failed)
        #expect(!model.isShown, "never a switch that might be wrong")
    }

    @Test func aFailedReloadKeepsWhatItKnew() async {
        let fail = Mutex(false)
        let model = model(load: {
            if fail.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return Self.ready
        })
        await model.load()
        fail.withLock { $0 = true }
        await model.load()
        #expect(model.phase == .ready(Self.ready))
    }

    @Test func turningOnSendsTheWordingTheyAgreedTo() async {
        let calls = Calls()
        let model = model(calls: calls)
        await model.load()
        #expect(await model.turnOn(.foundingUpdates))
        #expect(calls.all == [Call(email: .foundingUpdates, isOn: true, wording: "founding-updates-v1")])
        #expect(model.isOn(.foundingUpdates))
        #expect(model.errorMessage == nil)
    }

    @Test func turningOffNeedsNoAgreement() async {
        let calls = Calls()
        let model = model(calls: calls)
        await model.load()
        _ = await model.turnOn(.weeklyPlan)
        #expect(await model.turnOff(.weeklyPlan))
        #expect(calls.all.last == Call(email: .weeklyPlan, isOn: false, wording: nil))
        #expect(!model.isOn(.weeklyPlan))
    }

    @Test func aKidIsToldItsForAdults() async {
        let model = model(set: { throw Self.refused })
        await model.load()
        #expect(!(await model.turnOn(.weeklyPlan)))
        #expect(model.errorMessage == String(localized: "Only adults can get email from Foon."))
        #expect(!model.isOn(.weeklyPlan), "the switch stays off")
    }

    @Test func emailNotOnYetSaysSo() async {
        let model = model(set: { throw Self.emailOff })
        await model.load()
        #expect(!(await model.turnOn(.weeklyPlan)))
        #expect(model.errorMessage == String(localized: "Foon doesn't send email yet. Try again later."))
    }

    @Test func aConnectionProblemSaysTryAgain() async {
        let model = model(set: { throw URLError(.notConnectedToInternet) })
        await model.load()
        #expect(!(await model.turnOff(.weeklyPlan)))
        #expect(model.errorMessage == String(localized: "Couldn't change your email. Check your connection and try again."))
        model.clearError()
        #expect(model.errorMessage == nil)
    }
}
