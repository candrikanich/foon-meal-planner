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

        let household = try await households.createHousehold("Test family", "🌮", "Ann")
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
        let household = try await parent.createHousehold("Invite family", nil, "Ann")
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

        let household = try await HouseholdClient.live(phone).createHousehold("Two devices", nil, "Ann")
        #expect(try await HouseholdClient.live(mac).members(household.id).count == 1)

        #expect(await AuthClient.live(phone).signOutEverywhere())
        #expect(try await HouseholdClient.live(mac).members(household.id).isEmpty,
                "the Mac's unexpired token no longer reads the household")
        #expect(await !AuthClient.live(mac).accountStillExists(), "and the Mac notices its session is gone")
    }

    @Test func photosAreReadableOnlyByTheirHousehold() async throws {
        let ann = Self.newSupabaseClient()
        try await ann.auth.signUp(email: "foon-test-\(UUID().uuidString.lowercased())@example.com", password: Self.password)
        let household = try await HouseholdClient.live(ann).createHousehold("Photo family", nil, "Ann")

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
        let household = try await households.createHousehold("Library family", nil, "Ann")

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
        let household = try await households.createHousehold("Week family", nil, "Ann")
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
        let reloaded = try #require(try await weeks.week(household.id, sunday))
        #expect(reloaded.nights[1].attendance[owen.id] == true)
        #expect(reloaded.nights[1].effort == .rushed)

        let me = try #require(try await households.members(household.id).first { $0.firstName == "Ann" })
        var schedule = MemberDraft(me)
        schedule.usuallyAway = [6]
        let saved = try await households.updateMember(me.id, schedule.changes(from: me))
        #expect(saved.usuallyAway == [6])
        #expect(try await households.myHousehold()?.planningSettings == HouseholdSettings())
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
