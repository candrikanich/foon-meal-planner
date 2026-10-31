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

        var timed = MealDraft(saved)
        timed.cookMinutes = 45
        try await library.save(id, timed.validated())
        #expect(try await library.meals(household.id).first { $0.id == id }?.cookMinutes == 45)
        let timedCopyID = try await library.copy(id, "Our tacos, timed")
        #expect(try await library.meals(household.id).first { $0.id == timedCopyID }?.cookMinutes == 45)
        timed.cookMinutes = nil
        try await library.save(id, timed.validated())
        #expect(try await library.meals(household.id).first { $0.id == id }?.cookMinutes == nil,
                "clearing the time reaches the database")

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
        settings.missingEquipment = [.grill, .airFryer]
        settings.showsStartCooking = false
        try await households.updateKitchen(household.id, settings.kitchen)
        let saved = try #require(try await households.myHousehold()?.planningSettings)
        #expect(saved.dinnerTime == "17:30")
        #expect(saved.planningDay == 6)
        #expect(!saved.onboarded)
        #expect(saved.missingEquipment == [.grill, .airFryer])
        #expect(!saved.showsStartCooking)

        var stale = HouseholdSettings()
        stale.dinnerTime = "19:00"
        try await households.updateSettings(household.id, stale)
        #expect(try await households.myHousehold()?.planningSettings.missingEquipment == [.grill, .airFryer],
                "a stale save of the other settings keeps the kitchen")

        settings.missingEquipment = []
        try await households.updateKitchen(household.id, settings.kitchen)
        #expect(try await households.myHousehold()?.planningSettings.missingEquipment.isEmpty == true,
                "turning everything back on reaches the database")
    }

    @MainActor @Test func theFamilyTabSavesOnlyWhatChangedAndEditsAllergiesLater() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let households = HouseholdClient.live(supabase)
        let household = try await households.createHousehold("Family tab family", nil, "Ann", HouseholdSettings())
        #expect(try await households.latestWeekStart(household.id) == nil, "no plan yet, so the week start is free")

        // A stale phone: it opened with the defaults, and another planner has since moved dinner.
        var other = HouseholdSettings()
        other.dinnerTime = "17:30"
        try await households.updateRhythm(household.id, RhythmChanges(from: HouseholdSettings(), to: other))
        var draft = HouseholdSettings()
        draft.notificationPreset = .engaged
        draft.repeatWindowDays = 21
        try await households.updateRhythm(household.id, RhythmChanges(from: HouseholdSettings(), to: draft))
        let saved = try #require(try await households.myHousehold()?.planningSettings)
        #expect(saved.notificationPreset == .engaged)
        #expect(saved.repeatWindowDays == 21)
        #expect(saved.dinnerTime == "17:30", "the stale phone's save left dinner alone")

        try await households.saveTimeZone(household.id, "America/Denver")
        let zoned = try #require(try await households.myHousehold()?.planningSettings)
        #expect(zoned.timeZone == "America/Denver")
        #expect(zoned.dinnerTime == "17:30", "saving the time zone sends nothing else")

        // A week reads back as the day it starts.
        let start = WeekMath.start(of: saved.today(), weekStart: saved.weekStart)
        _ = try await WeekClient.live(supabase).create(household.id, start)
        #expect(try await households.latestWeekStart(household.id) == start)

        // A household that answered No in onboarding has no consent. Adding later records it, through the same model.
        var kid = MemberDraft()
        kid.firstName = "Nora"
        kid.ageGroup = .kid
        let nora = try await households.addMember(household.id, try #require(kid.validated()))
        let library = LibraryClient.live(supabase)
        let adding = AllergyEditorModel(memberID: nora.id, householdID: household.id, household: households, library: library)
        await adding.load()
        adding.answer.allergens = [.milk]
        adding.answer.otherText = "kiwi"
        #expect(await adding.save() == AllergyChoice(allergens: [.milk], custom: ["kiwi"]))
        #expect(Set(try await library.allergies(household.id).map(\.allergen)) == [.milk, .custom])

        let clearing = AllergyEditorModel(memberID: nora.id, householdID: household.id, household: households, library: library)
        await clearing.load()
        #expect(clearing.answer.otherText == "kiwi")
        clearing.answer = OnboardingModel.Answer()
        #expect(await clearing.save() == AllergyChoice())
        #expect(try await library.allergies(household.id).isEmpty)
    }

    @Test func editingSomeoneYouCantSeeComesBackAsPGRST116() async throws {
        let parent = try await Self.signedUpClient()
        let household = try await parent.createHousehold("Hidden family", nil, "Ann", HouseholdSettings())
        let ann = try #require(try await parent.members(household.id).first)
        let stranger = try await Self.signedUpClient()
        var changes = MemberChanges()
        changes.attendanceDefaults = AttendanceDefaults(usuallyAway: [1])

        do {
            _ = try await stranger.updateMember(ann.id, changes)
            Issue.record("row-level security should have hidden the row")
        } catch {
            #expect((error as? PostgrestError)?.code == "PGRST116", "HouseholdStore.save tells this apart by its code")
        }
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

    /// Save to library (#155): a retry after a lost answer links the same dish again, and a refusal has its own words.
    @MainActor
    @Test func anIdeaLinksToItsDishOnceHoweverOftenItsRetried() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let household = try await HouseholdClient.live(supabase).createHousehold("Idea family", "🌮", "Ann", HouseholdSettings())
        let ann = try #require(try await HouseholdClient.live(supabase).members(household.id).first)
        let library = LibraryClient.live(supabase)
        let ideas = IdeasClient.live(supabase)
        let idea = try await ideas.make(household.id, NewRequest(from: ann.id, title: "Chili",
                                                                 link: "https://recipes.example/chili"))
        let saved = RecipeImport(recipe: nil, title: nil, url: URL(string: "https://recipes.example/chili")!)
            .draft(householdSize: 4, named: "Chili")
        let dish = try await library.create(household.id, try saved.validated())

        try await ideas.update(idea, RequestUpdate(linkMealID: dish))
        try await ideas.update(idea, RequestUpdate(linkMealID: dish))
        #expect(try await ideas.requests(household.id).first { $0.id == idea }?.mealID == dish)
        let meals = try await library.meals(household.id)
        #expect(meals.count == 1)
        #expect(meals.first?.name == "Chili")
        #expect(meals.first?.sourceURL?.absoluteString == "https://recipes.example/chili")

        do {
            try await ideas.update(idea, RequestUpdate(linkMealID: UUID()))
            Issue.record("a dish that isn't this family's can't be linked")
        } catch {
            let code = (error as? PostgrestError)?.code
            #expect(code == "P0002", "refused by the rule, not a wiring mistake")
            #expect(!IdeasStore.message(for: .update, code: code).contains("connection"))
        }
        #expect(try await ideas.requests(household.id).first { $0.id == idea }?.mealID == dish, "and it stays linked")

        // A stale phone's own dish doesn't take over.
        let second = try await library.create(household.id, try MealDraft(newNamed: "Chili again").validated())
        do {
            try await ideas.update(idea, RequestUpdate(linkMealID: second))
            Issue.record("an idea with a dish keeps it")
        } catch {
            #expect((error as? PostgrestError)?.code == "FD014", "refused by the rule, not a wiring mistake")
        }
        #expect(try await ideas.requests(household.id).first { $0.id == idea }?.mealID == dish)
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

    @Test func awayDatesClearTheWeekAndOnlyTheirNights() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let households = HouseholdClient.live(supabase)
        let weeks = WeekClient.live(supabase)
        let household = try await households.createHousehold("Away family", nil, "Ann", HouseholdSettings())
        let ann = try #require(try await households.members(household.id).first)

        // 2037-11-01 is a Sunday, ahead of the clock.
        let sunday = CalendarDay(year: 2037, month: 11, day: 1)
        let week = try await weeks.create(household.id, sunday)
        #expect(week.nights[2].attendance[ann.id] == true)

        let tuesday = AwayDates(from: sunday.adding(days: 2), to: sunday.adding(days: 3))
        #expect(try await households.addAwayDates(household.id, tuesday) == [tuesday])
        #expect(try await households.myHousehold()?.planningSettings.awayDates == [tuesday])
        await #expect(throws: (any Error).self, "a swap onto an away night is refused") {
            try await weeks.setNight(NightUpdate(nightID: week.nights[2].id, quickPick: .takeout), true)
        }
        let during = try #require(try await weeks.week(household.id, sunday))
        #expect(during.nights[2].attendance[ann.id] == false)
        #expect(during.nights[4].attendance[ann.id] == true)

        var saved = HouseholdSettings()
        saved.takeoutNights = 2
        try await households.updateSettings(household.id, saved)
        #expect(try await households.myHousehold()?.planningSettings.awayDates == [tuesday],
                "saving settings doesn't touch them")

        let christmas = AwayDates(from: sunday.adding(days: 50), to: sunday.adding(days: 52))
        #expect(try await households.addAwayDates(household.id, christmas) == [tuesday, christmas],
                "a device that didn't know about the first keeps it")
        #expect(try await households.removeAwayDates(household.id, christmas) == [tuesday])
        #expect(try await households.removeAwayDates(household.id, tuesday) == [])
        let after = try #require(try await weeks.week(household.id, sunday))
        #expect(after.nights[2].attendance[ann.id] == true)
    }

    @Test func doubleItAndTheFreezerRoundTrip() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let households = HouseholdClient.live(supabase)
        let weeks = WeekClient.live(supabase)
        let freezer = FreezerClient.live(supabase)
        let library = LibraryClient.live(supabase)
        let household = try await households.createHousehold("Freezer family", nil, "Ann", HouseholdSettings())
        let chili = try await library.create(household.id, try MealDraft(newNamed: "Chili").validated())
        let tacos = try await library.create(household.id, try MealDraft(newNamed: "Tacos").validated())

        // 2037-11-01 is a Sunday, ahead of the clock.
        let sunday = CalendarDay(year: 2037, month: 11, day: 1)
        let week = try await weeks.create(household.id, sunday)
        let monday = week.nights[1], tuesday = week.nights[2], wednesday = week.nights[3]
        try await weeks.setNight(NightUpdate(nightID: monday.id, mealID: chili), false)
        try await weeks.setNight(NightUpdate(nightID: tuesday.id, mealID: tacos), false)

        let request = DoubleItRequest(nightID: monday.id, leftoversNightID: tuesday.id, expectedMeal: chili,
                                      expectedLeftoversMeal: tacos, expectedLeftoversPick: nil)
        try await weeks.doubleIt(request)
        var loaded = try #require(try await weeks.week(household.id, sunday))
        #expect(loaded.nights[2].leftoversFrom == monday.id)
        #expect(loaded.nights[2].quickPick == .leftovers)
        #expect(loaded.nights[1].locked)
        #expect(!loaded.listStale, "not approved, so no list to be behind")

        do {
            try await weeks.doubleIt(request)
            Issue.record("a dish is doubled once")
        } catch {
            #expect((error as? PostgrestError)?.code == "FD001")
        }

        try await weeks.undoDouble(monday.id)
        loaded = try #require(try await weeks.week(household.id, sunday))
        #expect(loaded.nights[2].mealID == tacos, "the dish Double it replaced comes back")
        #expect(loaded.nights[2].leftoversFrom == nil)

        try await weeks.approve(week.planID, [])
        try await weeks.doubleIt(request)
        loaded = try #require(try await weeks.week(household.id, sunday))
        #expect(loaded.listStale, "every phone can see the list is behind")
        try await weeks.undoDouble(monday.id)

        try await freezer.add(household.id, chili, CalendarDay(year: 2026, month: 1, day: 5))
        let item = try #require(try await freezer.items(household.id).first)
        #expect(item.mealName == "Chili")
        #expect(item.state == .in)
        #expect(item.plannedOn == nil)

        try await weeks.useFreezerItem(wednesday.id, item.id, "From the freezer, made Jan 5")
        loaded = try #require(try await weeks.week(household.id, sunday))
        #expect(loaded.nights[3].stashItemID == item.id)
        #expect(loaded.nights[3].mealName == "Chili")
        let planned = try #require(try await freezer.items(household.id).first)
        #expect(planned.state == .used)
        #expect(planned.plannedOn == wednesday.date)

        do {
            try await weeks.useFreezerItem(monday.id, item.id, "From the freezer")
            Issue.record("the same item can't go on two nights")
        } catch {
            #expect((error as? PostgrestError)?.code == "FD002")
        }

        try await weeks.setNight(NightUpdate(nightID: wednesday.id, quickPick: .takeout), true)
        let back = try #require(try await freezer.items(household.id).first)
        #expect(back.state == .in, "swapping the night puts it back")
        #expect(back.plannedOn == nil)

        try await freezer.setState(item.id, .archived)
        #expect(try await freezer.items(household.id).first?.state == .archived)
    }

    @Test func aPlannerSavesAndSwitchesSchedules() async throws {
        let households = try await Self.signedUpClient()
        let household = try await households.createHousehold("Season family", nil, "Ann", HouseholdSettings())
        var kid = MemberDraft()
        kid.firstName = "Owen"
        kid.usuallyAway = [1, 2]
        let owen = try await households.addMember(household.id, try #require(kid.validated()))

        let school = try await households.saveAttendanceTemplate(household.id, "School year")
        #expect(school.name == "School year")
        #expect(school.schedules[owen.id]?.usuallyAway == [1, 2])
        #expect(try await households.attendanceTemplates(household.id) == [school])

        var summer = MemberDraft(owen)
        summer.usuallyAway = []
        _ = try await households.updateMember(owen.id, summer.changes(from: owen))
        #expect(try await households.members(household.id).first { $0.id == owen.id }?.usuallyAway == [])

        try await households.applyAttendanceTemplate(school.id)
        #expect(try await households.members(household.id).first { $0.id == owen.id }?.usuallyAway == [1, 2])

        try await households.deleteAttendanceTemplate(school.id)
        #expect(try await households.attendanceTemplates(household.id).isEmpty)
        await #expect(throws: AttendanceTemplateError.notDeleted, "nothing deleted is reported, not a silent success") {
            try await households.deleteAttendanceTemplate(school.id)
        }
    }

    /// Household shapes (#49) through the real clients: a schedule's two keys don't overwrite each other, food rules merge
    /// on the server, and hiding a comment takes it out of what the family reads.
    @Test func householdShapesRoundTrip() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let households = HouseholdClient.live(supabase)
        let household = try await households.createHousehold("Shapes family", nil, "Ann", HouseholdSettings())
        let ann = try #require(try await households.members(household.id).first { $0.firstName == "Ann" })

        // The pattern, then the days, from two copies of the same profile.
        let first = CalendarDay(year: 2037, month: 11, day: 2)
        var kid = MemberDraft()
        kid.firstName = "Owen"
        kid.usuallyAway = [3]
        kid.awayPattern = AwayPattern(from: first)
        let owen = try await households.addMember(household.id, try #require(kid.validated()))
        #expect(owen.awayPattern == AwayPattern(from: first), "adding someone saves it")

        var days = MemberDraft(owen)
        days.usuallyAway = [4]
        let saved = try await households.updateMember(owen.id, days.changes(from: owen))
        #expect(saved.usuallyAway == [4])
        #expect(saved.awayPattern == AwayPattern(from: first))
        var ended = MemberDraft(saved)
        ended.awayPattern = nil
        let cleared = try await households.updateMember(owen.id, ended.changes(from: saved))
        #expect(cleared.awayPattern == nil)
        #expect(cleared.usuallyAway == [4])

        var pattern = MemberDraft(cleared)
        pattern.awayPattern = AwayPattern(from: first)
        _ = try await households.updateMember(owen.id, pattern.changes(from: cleared))
        let sunday = CalendarDay(year: 2037, month: 11, day: 1)
        let week = try await WeekClient.live(supabase).create(household.id, sunday)
        #expect(week.nights.filter { $0.attendance[owen.id] == false }.count == 6, "Monday to Saturday")
        #expect(week.nights.first { $0.date == sunday }?.attendance[owen.id] == true)

        // Eats separately.
        var tot = MemberDraft()
        tot.firstName = "Tot"
        tot.ageGroup = .kid
        tot.eatsSeparately = true
        let toddler = try await households.addMember(household.id, try #require(tot.validated()))
        #expect(toddler.eatsSeparately)

        // Food rules.
        #expect(try await households.setFoodRule(household.id, .meat, .lentFridays) == [FoodRule(avoid: .meat, nights: .lentFridays)])
        #expect(try await households.setFoodRule(household.id, .pork, .everyNight).count == 2)
        #expect(try await households.setFoodRule(household.id, .pork, nil) == [FoodRule(avoid: .meat, nights: .lentFridays)])
        var rhythm = HouseholdSettings()
        rhythm.takeoutNights = 2
        try await households.updateSettings(household.id, rhythm)
        #expect(try await households.myHousehold()?.planningSettings.foodRules == [FoodRule(avoid: .meat, nights: .lentFridays)])

        // A rating refused, and a comment hidden.
        let library = LibraryClient.live(supabase)
        let chili = try await library.create(household.id, try MealDraft(newNamed: "Chili").validated())
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let today = CalendarDay(Date(), calendar: newYork)
        let thisWeek = try await WeekClient.live(supabase).create(household.id, WeekMath.start(of: today, weekStart: 7))
        let tonight = try #require(thisWeek.nights.first { $0.date == today })
        try await WeekClient.live(supabase).setNight(NightUpdate(nightID: tonight.id, mealID: chili), false)
        let dinners = DinnerClient.live(supabase)
        await #expect(throws: PostgrestError.self, "nobody rates for someone who eats separately") {
            _ = try await dinners.react(tonight.id, toddler.id, .good)
        }
        _ = try await dinners.react(tonight.id, ann.id, .good)
        // Nothing in the app writes a comment yet: the column's there for #42's follow-up.
        try await supabase.from("reactions").update(["comment": "A little spicy"]).eq("member_id", value: ann.id).execute()
        let comments = try await library.comments(household.id)
        #expect(comments.map(\.text) == ["A little spicy"])
        let comment = try #require(comments.first)
        try await library.setCommentHidden(comment.id, true)
        #expect(try await library.comments(household.id).first?.hidden == true, "a planner still reads it, marked")
        try await library.setCommentHidden(comment.id, false)
        #expect(try await library.comments(household.id).first?.hidden == false)
    }

    @Test func aNightIsClaimedAndCreditedAndJobsAreSet() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let households = HouseholdClient.live(supabase)
        let household = try await households.createHousehold("Claims family", nil, "Ann", HouseholdSettings())
        let ann = try #require(try await households.members(household.id).first { $0.firstName == "Ann" })
        var kid = MemberDraft()
        kid.firstName = "Nora"
        kid.ageGroup = .kid
        let nora = try await households.addMember(household.id, try #require(kid.validated()))
        var tot = MemberDraft()
        tot.firstName = "Tot"
        tot.ageGroup = .kid
        tot.eatsSeparately = true
        let toddler = try await households.addMember(household.id, try #require(tot.validated()))

        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let today = CalendarDay(Date(), calendar: newYork)
        let weeks = WeekClient.live(supabase)
        let week = try await weeks.create(household.id, WeekMath.start(of: today, weekStart: 7))
        let tonight = try #require(week.nights.first { $0.date == today })
        let chili = try await LibraryClient.live(supabase).create(household.id, try MealDraft(newNamed: "Chili").validated())
        try await weeks.setNight(NightUpdate(nightID: tonight.id, mealID: chili), false)

        let dinners = DinnerClient.live(supabase)
        // Passing the phone for Nora, who has no account; then Ann, who can't take a night that's taken.
        try await dinners.claimNight(tonight.id, nora.id)
        let claims = try await dinners.claims(household.id, today)
        let claim = try #require(claims.first)
        #expect(claims.count == 1)
        #expect(claim.memberID == nora.id)
        #expect(claim.enteredByMemberID == ann.id, "and it says whose phone")
        #expect(claim.date == today)
        #expect(claim.nightMealID == chili)
        #expect(!claim.memberIsOut)
        await #expect("the second person gets a clear answer") {
            try await dinners.claimNight(tonight.id, ann.id)
        } throws: { ($0 as? PostgrestError)?.code == "FD005" }
        await #expect("someone who eats separately isn't the cook") {
            try await dinners.claimNight(tonight.id, toddler.id)
        } throws: { ($0 as? PostgrestError)?.code == "FD008" }

        // Taken back, it's gone from what's read. Offered again, it fills in who cooked when dinner's logged.
        try await dinners.releaseClaim(claim.id)
        #expect(try await dinners.claims(household.id, today).isEmpty)
        try await dinners.claimNight(tonight.id, nora.id)
        _ = try await dinners.react(tonight.id, ann.id, .good)
        let log = try #require(try await dinners.logs(household.id, today).first { $0.nightID == tonight.id })
        #expect(log.cookedByMemberID == nora.id)
        #expect(CookCredit.thisMonth(logs: [log], thanks: [], today: today).map(\.memberID) == [nora.id])

        // A guess can't be thanked. The follow-up leaves the cook alone, and then thanks lock it.
        await #expect("not until who cooked is settled") {
            try await dinners.thankTheChef(log.id)
        } throws: { ($0 as? PostgrestError)?.code == "22023" }
        try await dinners.correct(log.id, .leftovers(true))
        let settled = try #require(try await dinners.logs(household.id, today).first { $0.nightID == tonight.id })
        #expect(settled.isSettled)
        #expect(settled.cookedByMemberID == nora.id, "the leftovers answer leaves the cook")
        try await dinners.thankTheChef(log.id)
        await #expect("thanked, the cook stays, and it says why") {
            try await dinners.correct(log.id, .cook(nil))
        } throws: { ($0 as? PostgrestError)?.code == "FD011" }

        // Dinner jobs, one change at a time.
        #expect(try await households.setDinnerJob(household.id, .dishes, true).jobs == [.dishes])
        #expect(try await households.setDinnerJob(household.id, .setTable, true).jobs == [.dishes, .setTable])
        #expect(try await households.setDinnerJobPerson(household.id, ann.id, false).leftOut == [ann.id])
        var rhythm = HouseholdSettings()
        rhythm.takeoutNights = 2
        try await households.updateSettings(household.id, rhythm)
        let saved = try await households.myHousehold()?.planningSettings
        #expect(saved?.dinnerJobs == DinnerJobSettings(jobs: [.dishes, .setTable], leftOut: [ann.id]), "a settings save leaves them")
        #expect(saved?.takeoutNights == 2)
    }

    @Test func remindersReadTheWeeksAndWriteTheLog() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let households = HouseholdClient.live(supabase)
        let weeks = WeekClient.live(supabase)
        let library = LibraryClient.live(supabase)
        let dinners = DinnerClient.live(supabase)
        let reminders = NotificationClient.live(supabase)
        let household = try await households.createHousehold("Reminder family", nil, "Ann", HouseholdSettings())
        let ann = try #require(try await households.members(household.id).first)
        #expect(ann.notificationPrefs?.preset == nil, "an empty notification_prefs column reads as no override")

        let chili = try await library.create(household.id, try MealDraft(newNamed: "Chili").validated())
        struct PrepPatch: Encodable {
            let prep_steps: [PrepStep]
        }
        try await supabase.from("meals")
            .update(PrepPatch(prep_steps: [PrepStep(step: "Thaw the beef", leadHours: 24)]))
            .eq("id", value: chili)
            .execute()

        let today = CalendarDay(Date(), calendar: household.planningSettings.dayCalendar)
        let start = WeekMath.start(of: today, weekStart: household.planningSettings.weekStart,
                                   calendar: household.planningSettings.dayCalendar)
        let week = try await weeks.create(household.id, start)
        let tonight = try #require(week.nights.first { $0.date == today })
        try await weeks.setNight(NightUpdate(nightID: tonight.id, mealID: chili), false)
        try await weeks.approve(week.planID, [])
        _ = try await dinners.react(tonight.id, ann.id, .good)

        let read = try await reminders.weeks(household.id, start, start.adding(days: 7))
        let thisWeek = try #require(read.first)
        #expect(read.count == 1, "next week hasn't been started")
        #expect(thisWeek.isApproved)
        let night = try #require(thisWeek.nights.first { $0.id == tonight.id })
        #expect(night.mealID == chili)
        #expect(night.prepSteps.map(\.leadHours) == [24])
        #expect(night.hasLog)
        #expect(night.attendance[ann.id] == true)
        #expect(night.ratedBy == [ann.id], "the embedded rating comes through")
        #expect(night.loggedMealID == chili)

        // A cached copy reads back the same.
        let snapshot = ReminderSnapshot(pulledAt: .now, weeks: read)
        let cached = try JSONDecoder().decode(ReminderSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(cached.weeks == read)

        let row = UUID()
        let entry = NotificationLogEntry(id: row, type: ReminderKind.prep.rawValue, nightID: tonight.id, scheduledFor: .now,
                                         sentAt: nil, respondedAt: nil, response: nil)
        try await reminders.record(household.id, [entry])
        try await reminders.record(household.id, [NotificationLogEntry(id: row, type: ReminderKind.prep.rawValue, nightID: tonight.id,
                                                                       scheduledFor: .now, sentAt: .now, respondedAt: .now,
                                                                       response: "done")])
        struct LogRow: Decodable {
            let id: UUID
            let member_id: UUID
            let night_id: UUID?
            let response: String?
        }
        let rows: [LogRow] = try await supabase.from("notification_log").select().execute().value
        #expect(rows.count == 1)
        #expect(rows.first?.id == row)
        #expect(rows.first?.member_id == ann.id)
        #expect(rows.first?.night_id == tonight.id)
        #expect(rows.first?.response == "done")
    }

    @Test func planChangesAreLoggedAndUndone() async throws {
        let supabase = Self.newSupabaseClient()
        try await supabase.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com",
                                       password: Self.password)
        let households = HouseholdClient.live(supabase)
        let weeks = WeekClient.live(supabase)
        let library = LibraryClient.live(supabase)
        let household = try await households.createHousehold("Undo family", nil, "Ann", HouseholdSettings())
        let ann = try #require(try await households.members(household.id).first)
        let chili = try await library.create(household.id, try MealDraft(newNamed: "Chili").validated())
        let tacos = try await library.create(household.id, try MealDraft(newNamed: "Tacos").validated())
        let sunday = CalendarDay(year: 2037, month: 11, day: 1)
        let week = try await weeks.create(household.id, sunday)
        let tuesday = week.nights[2]

        // As an older app sends it: a plain write, with the log finding out for itself.
        try await weeks.setNight(NightUpdate(nightID: tuesday.id, mealID: chili, reason: "Picked"), true)
        try await weeks.setNight(NightUpdate(nightID: tuesday.id, mealID: tacos), true)
        var changes = try await weeks.planChanges(household.id)
        #expect(changes.count == 2)
        let swap = try #require(changes.first)
        #expect(swap.nightID == tuesday.id)
        #expect(swap.nightDate == tuesday.date)
        #expect(swap.actorID == ann.id)
        #expect(swap.kind == .pick)
        #expect(swap.before.mealName == "Chili")
        #expect(swap.after.mealName == "Tacos")
        #expect(swap.restorable)
        #expect(PlanChangeText.line(swap, members: [ann], today: sunday, calendar: .current) == "Ann swapped Tuesday to Tacos")

        // Two requests never read as one.
        #expect(PlanActivity.entries(changes).count == 2)
        try await weeks.setNights(week.planID, [
            NightUpdate(nightID: week.nights[3].id, mealID: chili), NightUpdate(nightID: week.nights[4].id, quickPick: .takeout)
        ])
        changes = try await weeks.planChanges(household.id)
        #expect(PlanChangeText.line(try #require(PlanActivity.entries(changes).first), members: [ann], today: sunday, calendar: .current)
            == "Ann planned 2 nights", "a Build through PostgREST is one entry")

        do {
            try await weeks.undoPlanChange(changes.last?.id ?? 0)
            Issue.record("only the last change on a night")
        } catch {
            #expect((error as? PostgrestError)?.code == "FD012")
        }

        try await weeks.undoPlanChange(swap.id)
        var loaded = try #require(try await weeks.week(household.id, sunday))
        #expect(loaded.nights[2].mealID == chili, "the night holds what it held")
        #expect(loaded.nights[2].reason == nil, "the chip doesn't come back: the log keeps no reason")
        let undone = try #require(try await weeks.planChanges(household.id).first)
        #expect(undone.kind == .undo)
        #expect(undone.actorID == ann.id)

        do {
            try await weeks.undoPlanChange(undone.id)
            Issue.record("an undo isn't undone")
        } catch {
            #expect((error as? PostgrestError)?.code == "FD013")
        }
        loaded = try #require(try await weeks.week(household.id, sunday))
        #expect(loaded.nights[2].mealID == chili)

        // Someone else's phone gets nothing back from this household.
        let other = Self.newSupabaseClient()
        try await other.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com", password: Self.password)
        #expect(try await WeekClient.live(other).planChanges(household.id).isEmpty)
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
