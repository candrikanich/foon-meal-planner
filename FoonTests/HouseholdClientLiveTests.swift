import CoreGraphics
import Foundation
import ImageIO
import Supabase
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Foon

/// Drives the real `.live` client through PostgREST, the RPC, grants, and RLS on the local stack.
/// Needs `supabase start` and `scripts/write-local-config.sh`; enable with `TEST_RUNNER_FOON_LOCAL_SUPABASE=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FOON_LOCAL_SUPABASE"] != nil))
struct HouseholdClientLiveTests {
    @Test func createsAHouseholdAndManagesItsMembers() async throws {
        let households = try await Self.signedUpClient()

        #expect(try await households.myHousehold() == nil)

        let household = try await households.createHousehold("Test family", "🌮", "Ann", HouseholdSettings())
        #expect(household.name == "Test family")
        #expect(try await households.myHousehold() == household)

        let owner = try #require(try await households.members(household.id).first)
        #expect(owner.firstName == "Ann")
        #expect(owner.guardian)

        var kid = MemberDraft()
        kid.firstName = "Nora"
        kid.ageGroup = .kid
        kid.avatar = "🐢"
        kid.status = .away
        kid.awayUntil = CalendarDay(year: 2026, month: 12, day: 20)
        let nora = try await households.addMember(household.id, try #require(kid.validated()))
        #expect(nora.awayUntil == CalendarDay(year: 2026, month: 12, day: 20))
        #expect(nora.avatar == "🐢")

        var home = MemberDraft(nora)
        home.status = .active
        home.avatar = nil
        let back = try await households.updateMember(nora.id, try #require(home.validated()).changes(from: nora))
        #expect(back.status == .active)
        #expect(back.awayUntil == nil, "clearing the return date reaches the database")
        #expect(back.avatar == nil, "clearing the avatar reaches the database")

        var removal = MemberDraft(back)
        removal.status = .removed
        let removed = try await households.updateMember(nora.id, removal.changes(from: back))
        #expect(removed.status == .removed)
    }

    @Test func aParentInvitesAndASecondAccountJoins() async throws {
        let parent = try await Self.signedUpClient()
        let household = try await parent.createHousehold("Invite family", nil, "Ann", HouseholdSettings())
        var kid = MemberDraft()
        kid.firstName = "Owen"
        kid.ageGroup = .kid
        let owen = try await parent.addMember(household.id, try #require(kid.validated()))

        await #expect(throws: (any Error).self, "a kid can't be invited before a parent consents") {
            _ = try await parent.createInvite(owen.id)
        }
        try await parent.recordParentalConsent(household.id, owen.id)
        #expect(try await parent.parentalConsentMemberIDs(household.id) == [owen.id])
        let code = try await parent.createInvite(owen.id)
        #expect(try await parent.invitedMemberIDs(household.id) == [owen.id])

        let newcomer = try await Self.signedUpClient()
        #expect(try await newcomer.redeemInvite("WRONG-2222-2222") == .invalid)
        #expect(try await newcomer.redeemInvite(InviteCode.normalized(code)) == .claimed)
        #expect(try await newcomer.myHousehold()?.id == household.id)
        #expect(try await parent.invitedMemberIDs(household.id).isEmpty, "a redeemed invite is no longer open")
        #expect(try await newcomer.redeemInvite(code) == .hasHousehold)

        try await parent.revokeParentalConsent(owen.id)
        #expect(try await newcomer.myHousehold() == nil, "withdrawing consent takes the kid out of the household")
        #expect(try await parent.parentalConsentMemberIDs(household.id).isEmpty)
    }

    @Test func signingOutEverywhereEndsOtherDevicesAccessAtOnce() async throws {
        let email = "foon-test-\(UUID().uuidString.lowercased())@example.com"
        let phone = Self.newSupabaseClient()
        try await phone.auth.signUp(email: email, password: Self.password)
        let mac = Self.newSupabaseClient()
        try await mac.auth.signIn(email: email, password: Self.password)

        let household = try await HouseholdClient.live(phone).createHousehold("Two devices", nil, "Ann", HouseholdSettings())
        #expect(try await HouseholdClient.live(mac).members(household.id).count == 1)

        #expect(await AuthClient.live(phone).signOutEverywhere())
        #expect(try await HouseholdClient.live(mac).members(household.id).isEmpty,
                "the Mac's unexpired token no longer reads the household")
        #expect(await !AuthClient.live(mac).accountStillExists(), "and the Mac notices its session is gone")
    }

    @Test func photosAreReadableOnlyByTheirHousehold() async throws {
        let ann = Self.newSupabaseClient()
        try await ann.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com", password: Self.password)
        let household = try await HouseholdClient.live(ann).createHousehold("Photo family", nil, "Ann", HouseholdSettings())

        let tiny = try Self.sampleJPEG()
        let path = try await PhotoStorageClient.live(ann).upload(household.id, try PhotoPreparation.prepare(tiny))
        #expect(path.hasPrefix(household.id.uuidString.lowercased() + "/meals/"))

        let url = try await PhotoStorageClient.live(ann).signedURL(path)
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "the household loads its photo")
        let expiry = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" })
        #expect(!(expiry.value ?? "").isEmpty, "signed URLs carry a token")

        let outsider = Self.newSupabaseClient()
        try await outsider.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com", password: Self.password)
        await #expect(throws: (any Error).self, "another household cannot sign a URL for it") {
            _ = try await PhotoStorageClient.live(outsider).signedURL(path)
        }
        await #expect(throws: (any Error).self, "another household cannot download it") {
            _ = try await outsider.storage.from(PhotoStorageClient.bucket).download(path: path)
        }
        await #expect(throws: (any Error).self, "another household cannot upload into its folder") {
            _ = try await PhotoStorageClient.live(outsider).upload(household.id, try PhotoPreparation.prepare(tiny))
        }

        let publicURL = Self.config.url.appending(path: "storage/v1/object/public/\(PhotoStorageClient.bucket)/\(path)")
        let (_, publicResponse) = try await URLSession.shared.data(from: publicURL)
        #expect((publicResponse as? HTTPURLResponse)?.statusCode != 200, "there is no public URL")
    }

    @Test func aPlannerAddsStarterDishesAndArchivesThem() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let households = HouseholdClient.live(supabase)
        let library = LibraryClient.live(supabase)
        let household = try await households.createHousehold("Library family", nil, "Ann", HouseholdSettings())

        let catalog = try await library.catalog()
        #expect(catalog.count >= 40, "the starter pack is seeded")
        #expect(catalog.map(\.sortOrder) == catalog.map(\.sortOrder).sorted())
        let tacos = try #require(catalog.first { $0.name == "Tacos" })
        #expect(!tacos.ingredients.isEmpty)

        let id = try await library.addFromCatalog(household.id, tacos.id)
        #expect(try await library.addFromCatalog(household.id, tacos.id) == id, "adding twice returns the same copy")
        let meal = try #require(try await library.meals(household.id).first)
        #expect(meal.id == id)
        #expect(meal.catalogMealID == tacos.id)
        #expect(meal.tags == tacos.tags)
        #expect(meal.ingredients.map(\.name) == tacos.ingredients)
        #expect(meal.ingredients.map(\.position) == meal.ingredients.map(\.position).sorted())

        var draft = MealDraft(meal)
        draft.name = "Our tacos"
        draft.stepsText = "Brown the beef\nWarm the shells"
        draft.link = "example.com/tacos"
        draft.tags = [.quick, .backup]
        draft.addIngredients("2 cups shredded cheese, Grandma's spice mix")
        try await library.save(id, draft.validated())
        let saved = try #require(try await library.meals(household.id).first { $0.id == id })
        #expect(saved.name == "Our tacos")
        #expect(saved.steps == ["Brown the beef", "Warm the shells"])
        #expect(saved.sourceURL?.absoluteString == "https://example.com/tacos")
        #expect(saved.tags == [.quick, .backup])
        #expect(saved.ingredients.suffix(2).map(\.name) == ["shredded cheese", "Grandma's spice mix"])
        #expect(saved.ingredients.last?.quantityText == nil)
        #expect(saved.prepSteps == meal.prepSteps)

        let copyID = try await library.copy(id, "Our tacos, spicy")
        let copy = try #require(try await library.meals(household.id).first { $0.id == copyID })
        #expect(copy.ingredients.map(\.name) == saved.ingredients.map(\.name))
        #expect(copy.catalogMealID == nil)

        try await library.setPhoto(saved, try PhotoPreparation.prepare(try Self.sampleJPEG()))
        let photoPath = try #require(try await library.meals(household.id).first { $0.id == id }?.photoPath)
        #expect(photoPath.hasPrefix(household.id.uuidString.lowercased() + "/meals/"))
        let (_, response) = try await URLSession.shared.data(from: try await library.photoURL(photoPath))
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "the new photo is readable through a signed URL")

        var quick = MealDraft(newNamed: "Soup night")
        quick.addIngredients("1 carton chicken broth, egg noodles")
        let soupID = try await library.create(household.id, quick.validated())
        let soup = try #require(try await library.meals(household.id).first { $0.id == soupID })
        #expect(soup.ingredients.map(\.name) == ["chicken broth", "egg noodles"])
        let nameOnly = try await library.create(household.id, MealDraft(newNamed: "Leftovers bowl").validated())
        #expect(try await library.meals(household.id).first { $0.id == nameOnly }?.ingredients.isEmpty == true)
        #expect(Set(try await library.itemNames(household.id)).isSuperset(of: ["chicken broth", "egg noodles"]))

        var withSides = MealDraft(saved)
        withSides.addSide("Soup night", library: try await library.meals(household.id))
        withSides.addSide("Garlic bread", library: [])
        try await library.save(id, withSides.validated())
        let sided = try #require(try await library.meals(household.id).first { $0.id == id })
        #expect(sided.sides.first == .meal(soupID))
        #expect(sided.sides.count == 2)
        if case .item(_, let name) = sided.sides.last { #expect(name == "Garlic bread") } else { Issue.record("item side") }
        var noSides = MealDraft(sided)
        noSides.sides = []
        try await library.save(id, noSides.validated())
        #expect(try await library.meals(household.id).first { $0.id == id }?.sides.isEmpty == true,
                "removing every side reaches the database")

        let items = ItemClient.live(supabase)
        let broth = try #require(soup.ingredients.first)
        try await items.update(broth.itemID, ItemChanges(note: .some("low sodium"), category: .pantry))
        let noted = try #require(try await library.meals(household.id).first { $0.id == soupID }?.ingredients.first)
        #expect(noted.note == "low sodium")
        #expect(noted.category == .pantry)
        try await items.update(broth.itemID, ItemChanges(note: .some(nil)))
        #expect(try await library.meals(household.id).first { $0.id == soupID }?.ingredients.first?.note == nil)

        try await library.setStatus(id, .archived)
        #expect(try await library.meals(household.id).first { $0.id == id }?.status == .archived)
        #expect(try await library.history(household.id).isEmpty, "nothing has been made yet")
        #expect(try await library.allergies(household.id).isEmpty)
    }

    @Test func aPlannerStartsTheWeekWithAttendanceFromSchedules() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let households = HouseholdClient.live(supabase)
        let weeks = WeekClient.live(supabase)
        let household = try await households.createHousehold("Week family", nil, "Ann", HouseholdSettings())
        var owenDraft = MemberDraft()
        owenDraft.firstName = "Owen"
        owenDraft.usuallyAway = [1, 2, 3, 4]
        let owen = try await households.addMember(household.id, try #require(owenDraft.validated()))
        #expect(owen.usuallyAway == [1, 2, 3, 4])

        let sunday = CalendarDay(year: 2026, month: 11, day: 1)
        #expect(try await weeks.week(household.id, sunday) == nil)
        let week = try await weeks.create(household.id, sunday)
        #expect(week.nights.map(\.date) == (0..<7).map { sunday.adding(days: $0) })
        #expect(week.nights[0].attendance[owen.id] == true, "Owen is home Sunday")
        #expect(week.nights[1].attendance[owen.id] == false, "and works Monday")
        #expect(try await weeks.create(household.id, sunday).planID == week.planID, "creating it again returns it")

        try await weeks.setExpected(week.nights[1].id, owen.id, true)
        try await weeks.setEffort(week.nights[1].id, .rushed)
        try await weeks.setLocked(week.nights[1].id, true)
        let reloaded = try #require(try await weeks.week(household.id, sunday))
        #expect(reloaded.nights[1].attendance[owen.id] == true)
        #expect(reloaded.nights[1].effort == .rushed)
        #expect(reloaded.nights[1].locked)

        let library = LibraryClient.live(supabase)
        let tacos = try #require(try await library.catalog().first { $0.name == "Tacos" })
        let mealID = try await library.addFromCatalog(household.id, tacos.id)
        try await weeks.setNights(week.planID, [
            NightUpdate(nightID: week.nights[2].id, mealID: mealID, reason: "Haven't had it in 3 weeks"),
            NightUpdate(nightID: week.nights[3].id, quickPick: .takeout, reason: "Takeout on the busiest night")
        ])
        let planned = try #require(try await weeks.week(household.id, sunday))
        #expect(planned.nights[2].mealID == mealID)
        #expect(planned.nights[2].mealName == "Tacos")
        #expect(planned.nights[2].reason == "Haven't had it in 3 weeks")
        #expect(planned.nights[3].quickPick == .takeout)

        // Swap works on a locked night (night 1 was locked above) and replaces a meal with a quick pick.
        try await weeks.setNight(NightUpdate(nightID: week.nights[1].id, mealID: mealID), true)
        try await weeks.setNight(NightUpdate(nightID: week.nights[2].id, quickPick: .eatOut), true)
        let swapped = try #require(try await weeks.week(household.id, sunday))
        #expect(swapped.nights[1].mealID == mealID)
        #expect(swapped.nights[2].mealID == nil)
        #expect(swapped.nights[2].quickPick == .eatOut)
        #expect(swapped.nights[2].reason == nil)
        #expect(swapped.nights[2].locked)

        // Traditions: set, change, remove; and Build saving a tradition night locked.
        try await weeks.setTradition(household.id, 2, Tradition(weekday: 2, pick: .meal(mealID), name: "Taco Tuesday"))
        try await weeks.setTradition(household.id, 5, Tradition(weekday: 5, pick: .quickPick(.takeout), name: nil))
        try await weeks.setTradition(household.id, 5, Tradition(weekday: 5, pick: .quickPick(.eatOut), name: "Out Friday"))
        #expect(try await weeks.traditions(household.id) == [
            Tradition(weekday: 2, pick: .meal(mealID), name: "Taco Tuesday"),
            Tradition(weekday: 5, pick: .quickPick(.eatOut), name: "Out Friday")
        ])
        try await weeks.setTradition(household.id, 5, nil)
        #expect(try await weeks.traditions(household.id).map(\.weekday) == [2])
        try await weeks.setNights(week.planID, [
            NightUpdate(nightID: week.nights[4].id, quickPick: .leftovers, reason: "Tradition", locked: true)
        ])
        #expect(try await weeks.week(household.id, sunday)?.nights[4].locked == true)

        // Approve: the weekly list lands with amounts and notes, and the week is stamped.
        let tacoMeal = try #require(try await library.meals(household.id).first { $0.id == mealID })
        let lines = WeeklyList.build(nights: [WeeklyList.Night(mealID: mealID, home: [])], library: [tacoMeal])
        try await weeks.approve(week.planID, lines)
        #expect(try await weeks.week(household.id, sunday)?.approvedAt != nil)
        let snapshot = try await SyncClient.live(supabase).fetchSnapshot(household.id, sunday)
        let weekly = snapshot.listItems.filter { $0.list == .weekly && $0.checkedAt == nil }
        #expect(Set(weekly.map(\.itemID)) == Set(lines.map(\.itemID)))
        #expect(weekly.contains { $0.quantity != nil })

        // Lists: a brand-new item, and "couldn't find it" removing a weekly line.
        let towels = try await ItemClient.live(supabase).ensure(household.id, "Paper towels", .household)
        _ = try await SyncClient.live(supabase).send(.addToList(householdID: household.id, itemID: towels, list: .quick,
                                                               urgency: .whenever, source: .manual, note: nil,
                                                               lineID: UUID()))
        let gone = try #require(weekly.first)
        _ = try await SyncClient.live(supabase).send(.removeFromList(listItemID: gone.id))
        let after = try await SyncClient.live(supabase).fetchSnapshot(household.id, sunday)
        #expect(!after.listItems.contains { $0.id == gone.id })
        #expect(after.listItems.contains { $0.itemID == towels && $0.list == .quick })
        #expect(after.items.first { $0.id == towels }?.category == .household)

        let me = try #require(try await households.members(household.id).first { $0.firstName == "Ann" })
        var schedule = MemberDraft(me)
        schedule.usuallyAway = [6]
        let saved = try await households.updateMember(me.id, schedule.changes(from: me))
        #expect(saved.usuallyAway == [6])
        #expect(try await households.myHousehold()?.planningSettings == HouseholdSettings())
    }

    @Test func onboardingSavesAllergiesAndTheRhythm() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let households = HouseholdClient.live(supabase)
        let household = try await households.createHousehold("Onboarding family", nil, "Ann", HouseholdSettings())
        var kid = MemberDraft()
        kid.firstName = "Nora"
        kid.ageGroup = .kid
        let nora = try await households.addMember(household.id, try #require(kid.validated()))

        try await households.grantAllergyConsent(household.id, AllergyConsent.textVersion)
        try await households.setAllergies(nora.id, [.milk, .treeNuts], ["kiwi"])
        let rows = try await LibraryClient.live(supabase).allergies(household.id)
        #expect(Set(rows.map(\.allergen)) == [.milk, .treeNuts, .custom])
        #expect(rows.first { $0.allergen == .custom }?.customText == "kiwi")

        var settings = HouseholdSettings()
        settings.dinnerTime = "17:30"
        settings.planningDay = 6
        settings.onboarded = false
        try await households.updateSettings(household.id, settings)
        let saved = try #require(try await households.myHousehold()?.planningSettings)
        #expect(saved.dinnerTime == "17:30")
        #expect(saved.planningDay == 6)
        #expect(!saved.onboarded)
    }

    @Test func dinnersAreConfirmedRatedAndCorrected() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let households = HouseholdClient.live(supabase)
        let household = try await households.createHousehold("Dinner family", nil, "Ann", HouseholdSettings())
        var kid = MemberDraft()
        kid.firstName = "Nora"
        kid.ageGroup = .kid
        let nora = try await households.addMember(household.id, try #require(kid.validated()))
        let ann = try #require(try await households.members(household.id).first { $0.firstName == "Ann" })

        let library = LibraryClient.live(supabase)
        var chili = MealDraft(newNamed: "Chili")
        chili.servings = 4
        let chiliID = try await library.create(household.id, try chili.validated())
        let tacosID = try await library.create(household.id, try MealDraft(newNamed: "Tacos").validated())

        // Today's night, planned as chili. (The household has no time zone set, so the server uses New York.)
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let today = CalendarDay(Date(), calendar: newYork)
        let week = try await WeekClient.live(supabase).create(household.id, WeekMath.start(of: today, weekStart: 7))
        let tonight = try #require(week.nights.first { $0.date == today })
        try await WeekClient.live(supabase).setNight(NightUpdate(nightID: tonight.id, mealID: chiliID), false)

        let dinners = DinnerClient.live(supabase)
        // We had something else, before anyone rated: tacos, not chili.
        let logID = try await dinners.confirm(tonight.id)
        try await dinners.correct(logID, .dish(mealID: tacosID, quickPick: nil))
        #expect(try await dinners.react(tonight.id, ann.id, .favorite) == logID)
        #expect(try await dinners.react(tonight.id, nora.id, .notForMe) == logID, "pass the phone, same dinner")
        try await dinners.correct(logID, .extras(leftovers: true, cookedByMemberID: ann.id))

        let logs = try await dinners.logs(household.id, today)
        let log = try #require(logs.first)
        #expect(logs.count == 1)
        #expect(log.mealName == "Tacos", "we had something else")
        #expect(log.verified)
        #expect(log.confirmedByMemberID == ann.id)
        #expect(log.cookedByMemberID == ann.id)
        #expect(log.leftovers == true)
        #expect(log.reaction(of: ann.id)?.kind == .favorite)
        #expect(log.reaction(of: nora.id)?.kind == .notForMe)
        await #expect(throws: (any Error).self, "once rated, the dish stays") {
            try await dinners.correct(logID, .dish(mealID: chiliID, quickPick: nil))
        }

        // Thanks, chef: Ann cooked, so Ann can't thank herself; nobody else here has an account.
        do {
            try await dinners.thankTheChef(logID)
            Issue.record("no thanking yourself")
        } catch {
            #expect((error as? PostgrestError)?.code == "22023", "refused by the rule, not a wiring mistake")
        }
        #expect(try await dinners.thanks(household.id, today).isEmpty)

        // Serving notes: Ann (the owner, a parent) writes Nora's; a blank note clears it.
        try await library.setServingNote(tacosID, nora.id, "Keep everything separate")
        #expect(try await library.servingNotes(household.id)
            == [ServingNote(mealID: tacosID, memberID: nora.id, note: "Keep everything separate")])
        try await library.setServingNote(tacosID, nora.id, " ")
        #expect(try await library.servingNotes(household.id).isEmpty)

        // The idea inbox: Ann asks for tacos on tomorrow's night, and crab legs for Nora (pass the phone).
        let ideas = IdeasClient.live(supabase)
        let crab = try await ideas.make(household.id, NewRequest(from: nora.id, title: "Crab legs", note: "since March"))
        _ = try await ideas.make(household.id, NewRequest(from: ann.id, mealID: tacosID, date: today.adding(days: 1)))
        #expect(try await ideas.toggleMeToo(crab, ann.id))
        try await ideas.update(crab, RequestUpdate(status: .special))
        let requests = try await ideas.requests(household.id)
        #expect(requests.count == 2)
        #expect(requests.first { $0.id == crab }?.status == .special)
        #expect(requests.first { $0.id == crab }?.plusOnes == [ann.id])
        #expect(requests.contains { $0.mealID == tacosID && $0.targetDate == today.adding(days: 1) })
        // Planned on tonight: the planned night's date comes back with it.
        let soup = try await ideas.make(household.id, NewRequest(from: ann.id, title: "Soup"))
        try await ideas.update(soup, RequestUpdate(status: .planned, nightID: tonight.id))
        #expect(try await ideas.requests(household.id).first { $0.id == soup }?.plannedDate == today)

        let verdicts = try await library.verdicts(household.id)
        #expect(Set(verdicts.map(\.memberID)) == [ann.id, nora.id])
        #expect(verdicts.allSatisfy { $0.mealID == tacosID })
        #expect(try await library.likes(household.id) == [MealLikes(mealID: tacosID, likes: 1)], "Ann's favorite")
        #expect(try await dinners.logs(household.id, today.adding(days: 1)).isEmpty, "only from the date asked")

        let nights = try await dinners.nights(household.id, today, today)
        #expect(nights.map(\.id) == [tonight.id])
        #expect(nights.first?.mealName == "Chili")
        try await dinners.setNotHome(tonight.id, nora.id)
        let after = try await dinners.nights(household.id, today, today)
        #expect(after.first?.attendance[nora.id] == false, "Nora wasn't home, said on Ann's phone")
    }

    @Test func aPlannerExportsTheHousehold() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let households = HouseholdClient.live(supabase)
        let household = try await households.createHousehold("Export family", "🌮", "Ann", HouseholdSettings())
        let data = try await households.exportHousehold(household.id)
        let export = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((export["household"] as? [String: Any])?["name"] as? String == "Export family")
        let members = try #require(export["members"] as? [[String: Any]])
        #expect(members.map { $0["first_name"] as? String } == ["Ann"])
        #expect(members.allSatisfy { $0["user_id"] == nil }, "no account ids in the export")
    }

    private static let config = try! SupabaseConfig.fromMainBundle()
    private static func sampleJPEG() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static let password = "local-test-password-1"

    private static func newSupabaseClient() -> SupabaseClient {
        let config = try! SupabaseConfig.fromMainBundle()
        return SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.anonKey,
            options: SupabaseClientOptions(auth: .init(storage: MemoryAuthStorage(), emitLocalSessionAsInitialSession: true))
        )
    }

    private static func signedUpClient() async throws -> HouseholdClient {
        let supabase = newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com", password: password)
        return .live(supabase)
    }
}

/// Keeps the test user's session out of the Keychain.
private final class MemoryAuthStorage: AuthLocalStorage {
    private let values = Mutex<[String: Data]>([:])

    func store(key: String, value: Data) throws { values.withLock { $0[key] = value } }
    func retrieve(key: String) throws -> Data? { values.withLock { $0[key] } }
    func remove(key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
}
