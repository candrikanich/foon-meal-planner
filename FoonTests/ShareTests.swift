import Foundation
import Testing
@testable import Foon

struct SharedItemTests {
    @Test func aWebLinkInTextIsALink() {
        #expect(SharedItem.Kind(sharedText: "  https://recipes.example/chili \n")
            == .link(URL(string: "https://recipes.example/chili")!, title: nil))
    }

    @Test func wordsAreText() {
        #expect(SharedItem.Kind(sharedText: "milk, eggs, bread") == .text("milk, eggs, bread"))
        #expect(SharedItem.Kind(sharedText: "   ") == nil)
    }

    @Test func oneLinkInACaptionIsALinkTitledWithTheRest() {
        #expect(SharedItem.Kind(sharedText: "Great chili! https://a.example/x?y=1")
            == .link(URL(string: "https://a.example/x?y=1")!, title: "Great chili"))
        #expect(SharedItem.Kind(sharedText: "look at   https://a.example \n this")
            == .link(URL(string: "https://a.example")!, title: "look at this"))
    }

    @Test func wordsThatLookLikeDomainsStayWords() {
        #expect(SharedItem.Kind(sharedText: "milk, eggs.com, bread") == .text("milk, eggs.com, bread"))
    }

    @Test func severalLinksAreText() {
        let text = "https://a.example and https://b.example"
        #expect(SharedItem.Kind(sharedText: text) == .text(text))
    }

    @Test func aLoneAddressWeCantUseIsntAShoppingItem() {
        #expect(SharedItem.Kind(sharedText: "foon://invite/ABC") == nil)
        #expect(SharedItem.Kind(sharedText: "https://a.example/" + String(repeating: "x", count: SharedItem.linkLimit)) == nil)
    }

    @Test func aTitleThatIsJustTheLinkIsDropped() {
        #expect(SharedItem.Kind(url: URL(string: "https://a.example")!, title: "https://a.example")
            == .link(URL(string: "https://a.example")!, title: nil))
    }

    @Test func limitsMatchWhatAnIdeaAllows() {
        #expect(SharedItem.titleLimit == NewRequest.titleLimit)
        #expect(SharedItem.linkLimit == NewRequest.linkLimit)
    }

    @Test func onlyWebLinksComeThrough() {
        #expect(SharedItem.Kind(url: URL(string: "https://a.example/x")!, title: "  Chili ")
            == .link(URL(string: "https://a.example/x")!, title: "Chili"))
        #expect(SharedItem.Kind(url: URL(string: "file:///tmp/secrets.txt")!, title: nil) == nil)
        #expect(SharedItem.Kind(url: URL(string: "foon://invite/ABC")!, title: nil) == nil)
        let tooLong = URL(string: "https://a.example/" + String(repeating: "x", count: SharedItem.linkLimit))!
        #expect(SharedItem.Kind(url: tooLong, title: nil) == nil, "past the server's limit for a link")
    }

    @Test func aTitleIsCutToTheServersLimitCountingScalars() {
        let title = String(repeating: "🌮", count: SharedItem.titleLimit + 5)
        guard case .link(_, let cut?)? = SharedItem.Kind(url: URL(string: "https://a.example")!, title: title) else {
            Issue.record("expected a title")
            return
        }
        #expect(cut.unicodeScalars.count == SharedItem.titleLimit)
    }

    @Test func longTextIsCutToTheLimit() {
        let long = String(repeating: "x", count: SharedItem.textLimit + 50)
        guard case .text(let text)? = SharedItem.Kind(sharedText: long) else {
            Issue.record("expected text")
            return
        }
        #expect(text.count == SharedItem.textLimit)
    }
}

struct SharedInboxTests {
    private func inbox() -> SharedInbox {
        SharedInbox(directory: URL.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)"))
    }

    @Test func itemsWaitOldestFirstUntilHandled() throws {
        let inbox = inbox()
        let first = SharedItem(createdAt: Date(timeIntervalSince1970: 100), kind: .text("milk"))
        let second = SharedItem(createdAt: Date(timeIntervalSince1970: 200), kind: .text("eggs"))
        try inbox.add(second)
        try inbox.add(first)
        #expect(inbox.pending() == [first, second])
        inbox.remove(first.id)
        #expect(inbox.pending() == [second])
    }

    @Test func aLinkSurvivesTheTrip() throws {
        let inbox = inbox()
        let item = SharedItem(kind: .link(URL(string: "https://a.example/x")!, title: "Chili"))
        try inbox.add(item)
        #expect(inbox.pending().first?.kind == item.kind)
    }

    @Test func whatYouSharedBeforeSigningInIsYours() throws {
        let inbox = inbox()
        try inbox.add(SharedItem(kind: .text("milk")))
        inbox.claim(for: UUID())
        #expect(inbox.pending().count == 1, "shared while signed out, then signed in")
    }

    @Test func anotherPersonSigningInNeverSeesYourShares() throws {
        let inbox = inbox()
        let ann = UUID()
        inbox.claim(for: ann)
        try inbox.add(SharedItem(kind: .text("milk")))
        inbox.claim(for: ann)
        #expect(inbox.pending().count == 1, "the same person coming back keeps theirs")
        inbox.claim(for: UUID())
        #expect(inbox.pending().isEmpty)
    }

    @Test func nothingYetIsEmptyAndClearEmptiesIt() throws {
        let inbox = inbox()
        #expect(inbox.pending().isEmpty)
        try inbox.add(SharedItem(kind: .text("milk")))
        inbox.clear()
        #expect(inbox.pending().isEmpty)
    }

    @Test func aCorruptFileIsSkippedAndRemoved() throws {
        let inbox = inbox()
        try inbox.add(SharedItem(kind: .text("milk")))
        let bad = inbox.directory.appending(path: "\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: bad)
        #expect(inbox.pending().count == 1)
        #expect(!FileManager.default.fileExists(atPath: bad.path()))
    }

    @Test func aFullInboxRefusesMore() throws {
        let inbox = inbox()
        for _ in 0..<SharedInbox.limit { try inbox.add(SharedItem(kind: .text("milk"))) }
        #expect(throws: SharedInbox.Full.self) { try inbox.add(SharedItem(kind: .text("eggs"))) }
    }
}

struct ShareRouterTests {
    private let recipe = URL(string: "https://recipes.example/chili")!

    @Test func aRecipeLinkCanBeImportedOrSaved() {
        #expect(ShareRouter.route(.link(recipe, title: "Chili")) == .recipeLink(recipe, title: "Chili"))
    }

    @Test(arguments: ["https://www.instagram.com/p/abc", "https://instagram.com/reel/abc", "https://vm.tiktok.com/abc",
                      "https://www.tiktok.com/@me/video/1", "https://m.facebook.com/x", "https://fb.watch/abc",
                      "https://youtu.be/abc", "https://www.youtube.com/watch?v=abc", "https://www.pinterest.com/pin/1",
                      "https://www.pinterest.co.uk/pin/1", "https://pin.it/abc", "https://www.threads.net/@a/post/1",
                      "https://www.threads.com/@a/post/1", "https://x.com/a/status/1", "https://twitter.com/a/status/1",
                      "https://instagr.am/p/abc", "https://fb.me/abc"])
    func socialLinksBecomeIdeas(link: String) {
        let url = URL(string: link)!
        #expect(ShareRouter.route(.link(url, title: "Reel")) == .socialLink(url, title: "Reel"))
    }

    @Test func aLookalikeHostIsntSocial() {
        let url = URL(string: "https://notinstagram.com/chili")!
        #expect(ShareRouter.route(.link(url, title: nil)) == .recipeLink(url, title: nil))
    }

    @Test func plainTextIsAShoppingList() {
        #expect(ShareRouter.route(.text("milk, eggs\n- bread")) == .shoppingList(["milk", "eggs", "bread"]))
    }

    @Test func theSameItemTwiceIsOneItem() {
        #expect(ShareRouter.route(.text("milk, eggs, Milk")) == .shoppingList(["milk", "eggs"]))
    }

    @Test func textWithNothingToBuyIsAnEmptyList() {
        #expect(ShareRouter.route(.text(" , ,")) == .shoppingList([]))
    }
}
