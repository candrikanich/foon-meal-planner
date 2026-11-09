import Foundation
import Supabase
import Testing
@testable import Foon

/// The allergy editor during a hold (#277): flags keep working and taking away still saves; adding waits.
@MainActor
struct AllergyEditorHoldTests {
    private let nora = UUID()
    private let household = Household.sample.id

    private func status(householdCurrent: Bool = false, current: String = AllergyConsent.textVersion,
                        ownCurrent: Bool = true) -> AgreementStatus {
        AgreementStatus(terms: .dormant, privacy: .dormant, allergy: .init(
            current: current, summary: nil, consented: true, householdCurrent: householdCurrent,
            held: !householdCurrent, ownCurrent: ownCurrent, ownVersion: OwnAllergyConsent.textVersion,
            ownSummary: nil
        ), kidsHeld: [])
    }

    private func editor(_ status: AgreementStatus, ownProfile: Bool = false, consents: LockedBox<[String]>,
                        set: (@Sendable () throws -> Void)? = nil) -> AllergyEditorModel {
        let rows = [AllergyRow(memberID: nora, allergen: .milk, customText: nil),
                    AllergyRow(memberID: nora, allergen: .eggs, customText: nil)]
        var client = HouseholdClient.fake(
            grantAllergyConsent: { _, version in consents.set(consents.value + [version]) },
            setAllergies: { _, _, _ in try set?() },
            allergyAlerts: { _ in .on }
        )
        client.agreements = { _ in status }
        return AllergyEditorModel(memberID: nora, householdID: household, ownProfile: ownProfile, household: client,
                                  library: .fake(allergies: { _ in rows }))
    }

    @Test func aParentsAgreeAndSaveAgreesToTheNewWording() async {
        let consents = LockedBox<[String]>([])
        let model = editor(status(), consents: consents)
        await model.load()
        #expect(model.addBlock == nil)
        model.answer.allergens.insert(.fish)
        #expect(model.needsConsent && model.canSave)
        #expect(await model.save() != nil)
        #expect(consents.value == [AllergyConsent.textVersion])
    }

    @Test func wordingThisBuildCantShowStillLetsAParentRemove() async {
        let consents = LockedBox<[String]>([])
        let model = editor(status(current: "allergy-data-v3"), consents: consents)
        await model.load()
        #expect(model.addBlock == .updateFoon)
        #expect(!model.canAdd)
        model.answer.allergens.insert(.fish)
        #expect(!model.canSave, "adding waits")
        model.answer.allergens = [.milk]
        #expect(!model.needsConsent, "it doesn't log wording that isn't in force")
        #expect(model.canSave, "taking one away still works")
        #expect(await model.save() != nil)
        #expect(consents.value.isEmpty)
    }

    @Test func anotherAdultRemovesTheirOwnDuringAHold() async {
        let model = editor(status(), ownProfile: true, consents: LockedBox([]))
        await model.load()
        #expect(model.addBlock == .waitingOnParent)
        model.answer.allergens = [.milk, .eggs, .fish]
        #expect(!model.canSave)
        model.answer.allergens = [.eggs]
        #expect(model.canSave)
    }

    @Test func theirOwnSayComesFirst() async {
        let model = editor(status(householdCurrent: true, ownCurrent: false), ownProfile: true,
                           consents: LockedBox([]))
        await model.load()
        #expect(model.addBlock == .ownAgreementNeeded)
        #expect(!model.canAdd)
    }

    @Test(arguments: [
        ("agreement_outdated", false,
         "Agree to Foon's new allergy wording on Family first. Taking one away still works."),
        ("own_agreement_needed", true, "Agree to keep your allergies in Foon first. Taking one away still works.")
    ])
    func aRefusalForAnOutdatedAgreementSaysWhich(hint: String, ownProfile: Bool, message: String) async {
        let refusal = PostgrestError(hint: hint, code: "42501", message: "refused")
        let model = editor(status(householdCurrent: true), ownProfile: ownProfile, consents: LockedBox([]),
                           set: { throw refusal })
        await model.load()
        model.answer.allergens.insert(.fish)
        #expect(await model.save() == nil)
        #expect(model.errorMessage == message)
    }
}
