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

        let code = try await parent.createInvite(owen.id)
        #expect(try await parent.invitedMemberIDs(household.id) == [owen.id])

        let newcomer = try await Self.signedUpClient()
        #expect(try await newcomer.redeemInvite("WRONG-2222-2222") == .invalid)
        #expect(try await newcomer.redeemInvite(InviteCode.normalized(code)) == .claimed)
        #expect(try await newcomer.myHousehold()?.id == household.id)
        #expect(try await parent.invitedMemberIDs(household.id).isEmpty, "a redeemed invite is no longer open")
        #expect(try await newcomer.redeemInvite(code) == .hasHousehold)
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
