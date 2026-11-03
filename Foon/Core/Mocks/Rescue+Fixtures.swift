import Foundation

extension TonightRescue.Idea {
    /// One idea of each kind, the backup flagged for milk, for previews.
    static let samples: [TonightRescue.Idea] = {
        let today = CalendarDay(Date())
        let library = LibraryMeal.sampleLibrary
        let (tacos, mac, pizza) = (library[0], library[1], library[3])
        let cooked = today.adding(days: -2)
        let item = FreezerItem(id: UUID(), mealID: mac.id, mealName: mac.name, madeOn: today.adding(days: -21),
                               state: .in)
        let nora = Member.sampleFamily[3]
        let milk = AllergyFlag(trigger: .allergen(.milk), members: [.init(id: nora.id, firstName: nora.firstName)],
                               ingredients: ["milk"])
        return [
            .init(kind: .leftovers(mealID: mac.id, name: mac.name, cookedOn: cooked), title: mac.name,
                  why: TonightRescue.leftoversWhy(name: mac.name, cookedOn: cooked, today: today),
                  minutes: TonightRescue.Estimate.leftovers, isEstimate: true, allergies: AllergyCheck(),
                  swapChoice: .quickPick(.leftovers)),
            .init(kind: .freezer(item), title: mac.name,
                  why: TonightRescue.freezerWhy(madeOn: item.madeOn, today: today),
                  minutes: TonightRescue.Estimate.freezer, isEstimate: true, allergies: AllergyCheck(),
                  swapChoice: .freezer(item, reason: FreezerStash.reason(madeOn: item.madeOn, today: today))),
            .init(kind: .backup(mealID: pizza.id), title: pizza.name,
                  why: TonightRescue.backupWhy(minutes: 15, everythingIn: true), minutes: 15, isEstimate: false,
                  allergies: AllergyCheck(flags: [milk]), swapChoice: .meal(id: pizza.id, name: pizza.name)),
            .init(kind: .quickDish(mealID: tacos.id), title: tacos.name,
                  why: TonightRescue.dishWhy(.dueForATurn, minutes: 30, isEstimate: true), minutes: 30,
                  isEstimate: true, allergies: AllergyCheck(), swapChoice: .meal(id: tacos.id, name: tacos.name)),
            .init(kind: .quickPick(.takeout), title: DayCardText.quickPickLabel(.takeout),
                  why: TonightRescue.fillerWhy(.takeout), minutes: nil, isEstimate: false, allergies: AllergyCheck(),
                  swapChoice: .quickPick(.takeout))
        ]
    }()
}
