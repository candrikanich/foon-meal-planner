import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

struct AllergyAlertsStateTests {
    @Test func aFamilyThatNeverAgreedHasNeverTurnedThemOn() {
        #expect(AllergyAlerts(revokedAt: []) == .neverOn)
    }

    @Test func anActiveConsentMeansOn() {
        #expect(AllergyAlerts(revokedAt: [nil]) == .on)
        #expect(AllergyAlerts(revokedAt: [.now.addingTimeInterval(-60), nil]) == .on, "turned off once, then back on")
    }

    @Test func onlyRevokedConsentsMeanOff() {
        #expect(AllergyAlerts(revokedAt: [.now]) == .off)
        #expect(AllergyAlerts(revokedAt: [.now.addingTimeInterval(-60), .now]) == .off)
    }
}

@MainActor
struct AllergyAlertsModelTests {
    nonisolated private static let refused = PostgrestError(code: "42501", message: "refused")

    private enum Call: Equatable {
        case revoke(UUID)
        case grant(UUID, String)
    }

    private final class Calls: Sendable {
        private let calls = Mutex<[Call]>([])
        var all: [Call] { calls.withLock { $0 } }
        func add(_ call: Call) { calls.withLock { $0.append(call) } }
    }

    private let household = Household.sample.id

    private func model(state: @escaping @Sendable () throws -> AllergyAlerts = { .on },
                       revoke: (@Sendable () throws -> Void)? = nil, grant: (@Sendable () throws -> Void)? = nil,
                       calls: Calls = Calls()) -> AllergyAlertsModel {
        AllergyAlertsModel(householdID: household, client: .fake(
            grantAllergyConsent: { id, version in
                try grant?()
                calls.add(.grant(id, version))
            },
            allergyAlerts: { _ in try state() },
            revokeAllergyConsent: { id in
                try revoke?()
                calls.add(.revoke(id))
            }
        ))
    }

    @Test func showsOnlyToAFamilyThatHasTurnedThemOn() async {
        let never = model(state: { .neverOn })
        await never.load()
        #expect(never.phase == .ready(.neverOn))
        #expect(!never.isShown, "families without allergies don't see allergy settings")

        let on = model(state: { .on })
        await on.load()
        #expect(on.isShown)

        let off = model(state: { .off })
        await off.load()
        #expect(off.isShown, "a family that turned them off can turn them back on")
    }

    @Test func aFailedLoadShowsNothing() async {
        let model = model(state: { throw URLError(.notConnectedToInternet) })
        await model.load()
        #expect(model.phase == .failed)
        #expect(!model.isShown, "never a switch that might be wrong")
    }

    @Test func aFailedReloadKeepsWhatItKnew() async {
        let fail = Mutex(false)
        let model = model(state: {
            if fail.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return .on
        })
        await model.load()
        fail.withLock { $0 = true }
        await model.load()
        #expect(model.phase == .ready(.on))
    }

    @Test func turningOffRevokesTheHouseholdsConsent() async {
        let calls = Calls()
        let model = model(calls: calls)
        await model.load()
        #expect(await model.turnOff())
        #expect(calls.all == [.revoke(household)])
        #expect(model.phase == .ready(.off))
        #expect(model.errorMessage == nil)
    }

    @Test func turningOnAsksForTheSameConsentAsOnboarding() async {
        let calls = Calls()
        let model = model(state: { .off }, calls: calls)
        await model.load()
        #expect(await model.turnOn())
        #expect(calls.all == [.grant(household, AllergyConsent.textVersion)])
        #expect(model.phase == .ready(.on))
    }

    @Test func aRefusedChangeSaysOnlyParentsCan() async {
        let model = model(revoke: { throw Self.refused })
        await model.load()
        #expect(!(await model.turnOff()))
        #expect(model.phase == .ready(.on), "nothing changed")
        #expect(model.errorMessage == "Only parents can turn allergy alerts on or off.")
    }

    @Test func anOfflineChangeSaysSoAndKeepsTheSwitch() async {
        let model = model(state: { .off }, grant: { throw URLError(.notConnectedToInternet) })
        await model.load()
        #expect(!(await model.turnOn()))
        #expect(model.phase == .ready(.off))
        #expect(model.errorMessage == "Couldn't change allergy alerts. Check your connection and try again.")
    }
}

@MainActor
struct LibraryErasedAllergiesTests {
    @Test func theFlagsGoEvenIfTheReloadFails() async {
        let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let reads = Mutex(0)
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(allergies: { _ in
            if reads.withLock({ $0 += 1; return $0 }) > 1 { throw URLError(.notConnectedToInternet) }
            return [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)]
        }))
        await store.load(members: [nora])
        #expect(!store.allergies.isEmpty)
        await store.allergiesErased(members: [nora])
        #expect(store.allergies.isEmpty, "the server erased them, so this phone mustn't keep flagging them")
    }
}
