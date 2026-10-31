import CoreGraphics
import CoreText
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
        inbox.remove(first)
        #expect(inbox.pending() == [second])
    }

    @Test func aLinkSurvivesTheTrip() throws {
        let inbox = inbox()
        let item = SharedItem(kind: .link(URL(string: "https://a.example/x")!, title: "Chili"))
        try inbox.add(item)
        #expect(inbox.pending().first?.kind == item.kind)
    }

    @Test func aPhotoWaitsBesideItsItemAndGoesWithIt() throws {
        let inbox = inbox()
        let item = SharedItem(kind: .file(.image))
        try inbox.add(item, fileData: Data("jpeg".utf8))
        #expect(inbox.pending() == [item], "the photo isn't an item of its own")
        let url = try #require(inbox.fileURL(for: item))
        #expect(url.pathExtension == "jpg")
        #expect(FileManager.default.fileExists(atPath: url.path()))
        inbox.remove(item)
        #expect(!FileManager.default.fileExists(atPath: url.path()), "deleted once it's handled")
        #expect(inbox.fileURL(for: SharedItem(kind: .text("milk"))) == nil)
    }

    @Test func aFileWithNoItemIsSweptOnceItsOld() throws {
        let inbox = inbox()
        try inbox.add(SharedItem(kind: .text("milk")))
        let orphan = inbox.directory.appending(path: "\(UUID().uuidString).jpg")
        try Data("jpeg".utf8).write(to: orphan)
        _ = inbox.pending()
        #expect(FileManager.default.fileExists(atPath: orphan.path()), "it might be an add in progress")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: orphan.path())
        _ = inbox.pending()
        #expect(!FileManager.default.fileExists(atPath: orphan.path()))
    }

    @Test func aCorruptItemsFileGoesWithIt() throws {
        let inbox = inbox()
        try inbox.add(SharedItem(kind: .text("milk")))
        let id = UUID().uuidString
        let photo = inbox.directory.appending(path: "\(id).jpg")
        try Data("jpeg".utf8).write(to: photo)
        try Data("not json".utf8).write(to: inbox.directory.appending(path: "\(id).json"))
        _ = inbox.pending()
        #expect(!FileManager.default.fileExists(atPath: photo.path()))
    }

    @Test func whatsWaitingStaysOutOfBackups() throws {
        let inbox = inbox()
        try inbox.add(SharedItem(kind: .text("milk")))
        #expect(try inbox.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
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

    @Test func photosAndPDFsAreRead() {
        #expect(ShareRouter.route(.file(.image)) == .capture(.image))
        #expect(ShareRouter.route(.file(.pdf)) == .capture(.pdf))
    }

    @Test func textWithNothingToBuyIsAnEmptyList() {
        #expect(ShareRouter.route(.text(" , ,")) == .shoppingList([]))
    }

    @Test(arguments: [("https://www.instagram.com/p/abc", "Instagram post"), ("https://instagr.am/p/abc", "Instagram post"),
                      ("https://vm.tiktok.com/abc", "TikTok post"), ("https://fb.watch/abc", "Facebook post"),
                      ("https://youtu.be/abc", "YouTube post"), ("https://www.pinterest.co.uk/pin/1", "Pinterest post"),
                      ("https://www.threads.net/@a/post/1", "Threads post"), ("https://twitter.com/a/status/1", "X post"),
                      ("https://www.allrecipes.com/chili", "allrecipes.com"), ("https://r.example/chili", "r.example")])
    func aLinkWithNoTitleIsCalledByItsSite(link: String, label: String) {
        #expect(ShareRouter.siteLabel(URL(string: link)!) == label)
    }

    @Test(arguments: ["https://pinterest.evil.example/pin/1", "https://www.pinterest.evil.com/pin/1", "https://notpinterest.com/pin/1",
                      "https://pinterest.xy/pin/1", "https://pinterest.com.xy/pin/1", "https://pinterest.co.xy/pin/1"])
    func aLookalikePinterestIsntPinterest(link: String) {
        let url = URL(string: link)!
        #expect(ShareRouter.route(.link(url, title: nil)) == .recipeLink(url, title: nil))
        #expect(!ShareRouter.siteLabel(url).contains("Pinterest"))
    }

    @Test func aTappableLinkAlwaysSaysWhereItGoes() {
        #expect(ShareRouter.linkLabel(URL(string: "https://www.instagram.com/p/abc")!) == "Instagram post · instagram.com")
        #expect(ShareRouter.linkLabel(recipe) == "recipes.example")
    }

    private let post = URL(string: "https://www.instagram.com/p/abc")!

    @Test(arguments: [("https://www.instagram.com/p/abc", "Instagram"), ("https://www.instagram.com/p/abc", "Login • Instagram"),
                      ("https://www.instagram.com/p/abc", "Cook on Instagram"),
                      ("https://www.tiktok.com/@me/video/1", "TikTok - Make Your Day"),
                      ("https://www.facebook.com/x", "Log into Facebook"), ("https://x.com/a/status/1", "X"),
                      ("https://www.threads.com/@a/post/1", "Threads • Log in"),
                      ("https://x.com/a/status/1", "Jack (@jack) on X"), ("https://www.facebook.com/x", "Facebook"),
                      ("https://www.instagram.com/p/abc", "   ")])
    func aSocialPageThatOnlyNamesItsSiteIsNoTitle(link: String, page: String) {
        #expect(ShareRouter.postTitle(page, for: URL(string: link)!) == nil)
    }

    @Test func noPageTitleIsNoTitle() {
        #expect(ShareRouter.postTitle(nil, for: post) == nil)
    }

    @Test func anInstagramTitleBecomesItsCaption() {
        #expect(ShareRouter.postTitle(#"Cook on Instagram: "Easy weeknight tacos""#, for: post) == "Easy weeknight tacos")
        #expect(ShareRouter.postTitle("Cook on Instagram: “Easy weeknight tacos”", for: post) == "Easy weeknight tacos")
    }

    @Test func aCaptionKeepsItsOwnQuotes() {
        #expect(ShareRouter.postTitle(#"Cook on Instagram: "She called it "the best"""#, for: post) == #"She called it "the best""#)
        #expect(ShareRouter.postTitle(#"Cook on Instagram: ""Best" tacos ever""#, for: post) == #""Best" tacos ever"#)
    }

    @Test func facebooksCountsAndNameComeOff() {
        let video = URL(string: "https://www.facebook.com/watch/?v=1")!
        #expect(ShareRouter.postTitle("2.8M views · 1.3K reactions | Easy tacos | Facebook", for: video) == "Easy tacos")
        #expect(ShareRouter.postTitle("Easy tacos | Facebook", for: video) == "Easy tacos")
    }

    @Test func aCutTitleDoesntEndOnPunctuation() throws {
        let long = #"Cook on Instagram: "Introducing Ballroom in Focus, the largest digital archive of Ballroom history, curated with friends""#
        #expect(ShareRouter.postTitle(long, for: post) == "Introducing Ballroom in Focus, the largest digital archive of Ballroom history")
    }

    @Test func aLongCaptionFitsAnIdeaAndEndsOnAWholeWord() throws {
        let words = String(repeating: "tacos ", count: 30)
        let title = try #require(ShareRouter.postTitle(#"Cook on Instagram: "\#(words)"#, for: post))
        #expect(title.count <= SharedItem.titleLimit)
        #expect(title.hasSuffix("tacos"))
    }

    @Test func aRealSocialTitleStays() {
        let video = URL(string: "https://www.youtube.com/watch?v=abc")!
        #expect(ShareRouter.postTitle("Best chili ever - YouTube", for: video) == "Best chili ever - YouTube")
        #expect(ShareRouter.postTitle("Best chili on YouTube", for: video) == "Best chili on YouTube")
        #expect(ShareRouter.postTitle("The best chili blog in Ohio", for: video) == "The best chili blog in Ohio")
    }

    @Test func anOrdinaryPageKeepsItsTitle() {
        #expect(ShareRouter.postTitle("Instagram", for: recipe) == "Instagram")
    }

    private let captionPost = "1 like, 2 comments - cook on June 1, 2026: \"Tacos\\nIngredients:\\n1 lb beef\\n2 cups rice\\nDirections:\\nBrown it.\"."
        .replacing("\\n", with: "\n")

    @Test func anIdeaFromAReadPostKeepsTheNameOnTheScreen() throws {
        let page = RecipeImport(recipe: nil, title: "Instagram", caption: captionPost, url: post)
        let read = try #require(page.captionRecipe(householdSize: 4))
        #expect(ShareRouter.ideaTitle(typed: "", read: read.draft) == "Tacos")
        var edited = read.draft
        edited.name = "Friday tacos"
        #expect(ShareRouter.ideaTitle(typed: "An old name", read: edited) == "Friday tacos")
        #expect(ShareRouter.ideaTitle(typed: "Typed", read: nil) == "Typed")
    }

    @Test func aPostsCaptionBecomesTheWholeDish() throws {
        let page = RecipeImport(recipe: nil, title: "Instagram", caption: captionPost, url: post)
        let read = try #require(page.captionRecipe(householdSize: 4))
        #expect(read.draft.name == "Tacos")
        #expect(read.draft.lines.count == 2)
        #expect(read.draft.stepsText == "Brown it.")
        #expect(read.draft.link == post.absoluteString)
        #expect(!read.isTruncated)
    }

    @Test func someonesOwnNameBeatsTheCaptionsGuess() throws {
        let page = RecipeImport(recipe: nil, title: nil, caption: captionPost, url: post)
        #expect(page.captionRecipe(householdSize: 4, named: "Nora's tacos")?.draft.name == "Nora's tacos")
    }

    @Test func aCaptionCutShortSaysSo() throws {
        let page = RecipeImport(recipe: nil, title: nil, caption: captionPost, captionTruncated: true, url: post)
        #expect(page.captionRecipe(householdSize: 4)?.isTruncated == true)
    }

    @Test func onlyASocialPostsCaptionIsARecipe() {
        let blog = RecipeImport(recipe: nil, title: "Chili", caption: captionPost, url: recipe)
        #expect(blog.captionRecipe(householdSize: 4) == nil)
        let noRecipe = RecipeImport(recipe: nil, title: nil, caption: "Best dinner ever!! #yum", url: post)
        #expect(noRecipe.captionRecipe(householdSize: 4) == nil)
        let card = RecipeImport.Recipe(name: "Card", servings: 4, ingredients: ["1 lb beef"], steps: [], imageURL: nil)
        let carded = RecipeImport(recipe: card, title: nil, caption: captionPost, url: post)
        #expect(carded.captionRecipe(householdSize: 4) == nil)
    }

    @Test func aDishFromAPostWithNoTitleIsntNamedAfterTheAddress() {
        let page = RecipeImport(recipe: nil, title: "Instagram", url: post)
        #expect(page.draft(householdSize: 4).name == "Instagram post")
    }
}

struct RecipeTextParserTests {
    private func names(_ lines: [String]) -> [String] { RecipeTextParser.parse(lines).ingredients.map(\.name) }

    @Test func aRecipeWithHeaders() {
        let capture = RecipeTextParser.parse([
            "Grandma's Chili", "Serves 6", "Ingredients", "1 lb ground beef", "2 cans beans", "salt",
            "Directions", "1. Brown the beef in a large pot over", "medium heat.", "2. Add the beans.", "Simmer for 30 minutes."
        ])
        #expect(capture.name == "Grandma's Chili")
        #expect(capture.servings == 6)
        #expect(capture.ingredients.map(\.name) == ["ground beef", "beans", "salt"])
        #expect(capture.steps == ["Brown the beef in a large pot over medium heat.", "Add the beans.", "Simmer for 30 minutes."])
    }

    @Test func noHeadersStillFindsTheParts() {
        let capture = RecipeTextParser.parse([
            "Quick Tacos", "1 lb ground beef", "- taco shells",
            "Cook the beef until browned, then spoon it into the shells and top with cheese."
        ])
        #expect(capture.name == "Quick Tacos")
        #expect(capture.ingredients.map(\.name) == ["ground beef", "taco shells"])
        #expect(capture.steps.count == 1)
    }

    // Allergy flags read ingredients only: an ingredient misfiled as a step is never flagged.
    @Test func aLongIngredientDoesntPushTheRestIntoSteps() {
        let long = "1 can (15 ounces) low-sodium kidney beans, drained, rinsed well, and patted dry with a towel"
        let capture = RecipeTextParser.parse(["Ingredients", "1 lb beef", long, "2 tbsp peanut butter", "salt",
                                              "Directions", "1. Brown it."])
        #expect(capture.ingredients.count == 4)
        #expect(capture.ingredients.map(\.name).contains("peanut butter"))
        #expect(capture.steps == ["Brown it."])
    }

    @Test func aBlogIntroDoesntHideTheIngredients() {
        let capture = RecipeTextParser.parse([
            "Our Favorite Chili",
            "We have been making this chili every winter since the kids were small, and it never lasts long.",
            "1 lb beef", "2 tbsp peanut butter"
        ])
        #expect(capture.name == "Our Favorite Chili")
        #expect(capture.ingredients.map(\.name) == ["beef", "peanut butter"])
        #expect(capture.steps.isEmpty)
    }

    @Test func twoColumnsInterleavedKeepTheIngredients() {
        let capture = RecipeTextParser.parse([
            "Ingredients", "Directions", "1 lb beef", "1. Brown the beef well.", "2 tbsp peanut butter", "2. Stir it in."
        ])
        #expect(capture.ingredients.map(\.name) == ["beef", "peanut butter"])
        #expect(capture.steps == ["Brown the beef well.", "Stir it in."])
    }

    @Test func numberedIngredients() {
        #expect(names(["Ingredients", "1. 2 cups flour", "2. peanut butter"]) == ["flour", "peanut butter"])
    }

    @Test func aWrappedStepStartingWithANumberStaysInTheStep() {
        let capture = RecipeTextParser.parse(["Directions", "1. Simmer the pot for", "30 minutes, then serve."])
        #expect(capture.ingredients.isEmpty)
        #expect(capture.steps == ["Simmer the pot for 30 minutes, then serve."])
    }

    @Test func aPlainShoppingListIsAllItems() {
        #expect(names(["milk", "eggs", "bread"]) == ["milk", "eggs", "bread"])
        #expect(RecipeTextParser.parse(["milk", "eggs", "bread"]).name == nil)
        #expect(names(["Groceries", "milk", "eggs", "2 loaves bread"]) == ["milk", "eggs", "bread"])
        #expect(names(["Ingredients:", "milk", "eggs", "2 loaves bread"]) == ["milk", "eggs", "bread"])
    }

    @Test func aLooseItemAfterTheFirstIngredientIsKept() {
        #expect(names(["Tacos", "1 lb beef", "taco shells", "peanut sauce"]) == ["beef", "taco shells", "peanut sauce"])
    }

    @Test func aScreenshotsChromeIsDropped() {
        let capture = RecipeTextParser.parse([
            "9:41", "5G", "allrecipes.com", "Grandma's Chili", "4.8 stars (120)", "Prep time: 10 min", "Ingredients",
            "1 lb beef", "Advertisement", "Page 3", "3", "www.foo.com/chili", "salt"
        ])
        #expect(capture.name == "Grandma's Chili")
        #expect(capture.ingredients.map(\.name) == ["beef", "salt"])
    }

    @Test func aTitleCanStartWithANumber() {
        let capture = RecipeTextParser.parse(["30 Minute Chili", "Ingredients", "1 lb beef"])
        #expect(capture.name == "30 Minute Chili")
        #expect(capture.ingredients.map(\.name) == ["beef"])
    }

    @Test func subHeadersAndOtherHeaderWordings() {
        #expect(names(["Ingredients (serves 4)", "For the sauce:", "milk", "For the noodles", "flour"]) == ["milk", "flour"])
        #expect(names(["What you'll need", "milk"]) == ["milk"])
    }

    @Test func aSubHeaderWithTheIngredientOnItsLineKeepsIt() {
        let found = names(["Ingredients", "For the sauce: 2 tbsp peanut butter", "salt"])
        #expect(found.count == 2)
        #expect(found[0].contains("peanut butter"), "allergy flags need to see it")
    }

    @Test func shortLinesBetweenTheNameAndTheIngredientsAreKept() {
        let capture = RecipeTextParser.parse(["Chili", "peanut butter", "1 lb beef", "Directions", "1. Stir."])
        #expect(capture.name == "Chili")
        #expect(capture.ingredients.map(\.name) == ["peanut butter", "beef"])
    }

    @Test func enormousTextIsBounded() {
        let lines = Array(repeating: String(repeating: "x", count: 100_000), count: 100_000)
        let capture = RecipeTextParser.parse(["Directions", "1. Stir"] + lines)
        #expect(capture.steps.joined().count <= RecipeTextParser.textLimit)
        let draft = RecipeTextParser.Capture(ingredients: Array(repeating: ParsedIngredient(name: "x", quantity: nil), count: 500))
        #expect(draft.draft(householdSize: 4).lines.count == RecipeTextParser.ingredientLimit)
        #expect(draft.isTruncated, "the review screen says some were left out")
    }

    @Test func limitsCountScalarsLikeAMealDoes() throws {
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 5000)
        let capture = RecipeTextParser.Capture(name: "Chili", steps: [family])
        #expect(throws: Never.self) { _ = try capture.draft(householdSize: 4).validated() }
    }

    @Test func notesAndNutritionEndTheRecipe() {
        let capture = RecipeTextParser.parse(["Directions", "1. Stir.", "Notes", "Freezes well.", "Nutrition Facts",
                                              "300 calories"])
        #expect(capture.steps == ["Stir."], "Foon never keeps nutrition")
    }

    @Test func stepLabels() {
        #expect(RecipeTextParser.parse(["Step 1", "Brown the beef", "Step 2", "Add beans"]).steps
            == ["Brown the beef", "Add beans"])
        #expect(RecipeTextParser.parse(["Step 1: Brown the beef.", "Step 2: Add beans."]).steps
            == ["Brown the beef.", "Add beans."])
    }

    @Test func aCaptionWithARecipe() throws {
        let capture = try #require(RecipeTextParser.parseCaption("""
        Weeknight chili!
        Ingredients:
        1 lb beef
        2 tbsp peanut butter
        Directions:
        1. Brown the beef.
        #dinner #easy
        """))
        #expect(capture.name == "Weeknight chili!")
        #expect(capture.ingredients.map(\.name) == ["beef", "peanut butter"])
        #expect(capture.steps == ["Brown the beef."])
    }

    /// A real post, shared from Instagram on a phone.
    @Test func aDecoratedCaption() throws {
        let capture = try #require(RecipeTextParser.parseCaption("""
        🍗🧄🧀 SAVORY BAKED CAESAR CHICKEN WITH PARMESAN SAUCE
        💬 COMMENT “CAESAR” and I’ll send you the full recipe!
        👇 INGREDIENTS
        4 boneless, skinless chicken breasts
        ½ cup Caesar dressing
        ½ cup sour cream
        ½ cup freshly grated Parmesan cheese
        3 cloves garlic, minced
        1 tsp Italian seasoning
        👩‍🍳 INSTRUCTIONS
        1️⃣ Preheat the oven.
        2️⃣ Bake the chicken.
        """))
        #expect(capture.name == "Savory Baked Caesar Chicken with Parmesan Sauce")
        #expect(capture.ingredients.count == 6)
        #expect(capture.ingredients.first?.name.contains("chicken breasts") == true)
        #expect(!capture.ingredients.contains { $0.name.localizedCaseInsensitiveContains("comment") })
        #expect(!capture.ingredients.contains { $0.name.localizedCaseInsensitiveContains("ingredients") })
        #expect(capture.steps == ["Preheat the oven.", "Bake the chicken."])
    }

    @Test func aCaptionsHeaderCanHaveItsEmojiLast() throws {
        let capture = try #require(RecipeTextParser.parseCaption("Tacos\nINGREDIENTS 👇\n1 lb beef\n2 cups rice"))
        #expect(capture.ingredients.count == 2)
    }

    @Test func aListWithItsOwnAmountsSplitsEvenOnSeveralLines() throws {
        let capture = try #require(RecipeTextParser.parseCaption("Ingredients:\n1 cup flour, 1 tsp salt\n2 cups milk"))
        #expect(capture.ingredients.count == 3)
    }

    @Test func aPromotionIsntAnIngredientOrAName() throws {
        let capture = try #require(RecipeTextParser.parseCaption("""
        Comment RECIPE and I'll send it!
        Tacos
        Ingredients:
        1 lb beef
        2 cups rice
        Link in bio
        """))
        #expect(capture.name == "Tacos")
        #expect(capture.ingredients.count == 2)
    }

    private func savedNames(_ caption: String) throws -> [String] {
        let capture = try #require(RecipeTextParser.parseCaption(caption))
        return capture.draft(householdSize: 4).lines.map(\.name)
    }

    @Test(arguments: [
        ("Dish\nIngredients:\n1 lb boneless skinless chicken thighs, 2 tbsp creamy peanut butter, soy sauce, lime juice\nsalt to taste", "peanut"),
        ("Dish\nIngredients:\n8 oz wide flat rice noodles from the store, 2 eggs, 1 cup shrimp, and peanuts\n1 tbsp oil", "shrimp"),
        ("Dish\nIngredients:\nFor the sauce:\ncreamy peanut butter, soy sauce, fish sauce, sesame oil, lime juice, brown sugar\nFor the chicken:\n1 lb chicken thighs", "sesame"),
        ("Dish\nIngredients:\nFor the sauce: 3 tbsp creamy peanut butter, 2 tbsp soy sauce, 1 tbsp fish sauce\nFor the noodles: 8 oz noodles, 2 eggs", "fish sauce"),
        ("Dish\nIngredients:\n2 cups a very long blend of mixed roasted nuts from the store, peanuts\n1 tbsp oil", "peanuts"),
        ("Tacos\nIngredients:\n1 lb beef\n2 cups rice\n3 tbsp peanut butter (full recipe in bio)", "peanut"),
        ("Tacos\nIngredients:\n1 lb beef\n2 cups rice, 1 cup shrimp - full recipe link in bio\n1 tsp salt", "shrimp"),
        ("Tacos\nIngredients:\n1 lb beef\n2 cups rice\nPeanut sauce, link in bio", "peanut"),
    ])
    func anAllergenSurvivesToTheSavedDish(caption: String, allergen: String) throws {
        #expect(try savedNames(caption).contains { $0.localizedCaseInsensitiveContains(allergen) })
    }

    /// Whole, the first part would cancel the allergen in the second.
    @Test(arguments: [("8 oz gluten-free pasta, flour for dusting", "flour for dusting"), ("8 oz vegan sausage, parmesan to serve", "parmesan to serve"),
                      ("2 cups rice, flour for dredging", "flour for dredging"), ("2 cups cooked rice, milk", "milk"),
                      ("2 cups vegan broth, shrimp", "shrimp"), ("1 cup nut-free granola, pecans", "pecans"), ("1 cup soy-free tamari, tofu", "tofu")])
    func aSecondItemGetsItsOwnLine(line: String, item: String) throws {
        #expect(try savedNames("Dish\nIngredients:\n\(line)\n1 tsp salt").contains(item))
    }

    @Test(arguments: ["4 boneless, skinless chicken breasts", "3 cloves garlic, finely minced", "2 tbsp butter, at room temperature"])
    func aDescriptionStaysWithItsIngredient(line: String) throws {
        #expect(try savedNames("Dish\nIngredients:\n\(line)\n1 tsp salt").count == 2)
    }

    @Test(arguments: [("Dish\nIngredients (contains peanuts, shrimp)\n1 lb beef\n1 cup rice", "shrimp"),
                      ("Dish\n👇 INGREDIENTS (contains peanuts, soy) 👇\n1 lb beef\n1 cup rice", "peanuts"),
                      ("Dish\nIngredients (contains peanuts)\n1 lb beef\n1 cup rice", "peanuts"),
                      ("Dish\nIngredients:\n4 gluten-free boneless, flour tortillas\n1 tsp salt", "flour tortillas"),
                      ("Dish\nIngredients:\n4 vegan large, shrimp\n1 tsp salt", "shrimp"),
                      ("Dish\nIngredients:\nComment PEANUT: peanut butter; shrimp; eggs\n1 lb beef\n1 cup rice", "shrimp"),
                      ("Dish\nIngredients:\nTag a friend! peanut butter • shrimp • eggs\n1 lb beef\n1 cup rice", "shrimp"),
                      ("Dish\nIngredients:\nComment PEANUT - peanut butter and shrimp\n1 lb beef\n1 cup rice", "shrimp")])
    func aNoteOrListKeepsItsAllergen(caption: String, allergen: String) throws {
        #expect(try savedNames(caption).contains { $0.localizedCaseInsensitiveContains(allergen) })
    }

    @Test(arguments: ["notes", "method", "nutrition info below", "makes 2 cups peanut sauce", "for the sauce", "print"])
    func aHeaderNoteCantEndTheList(note: String) throws {
        let names = try savedNames("Dish\nIngredients:\n1 cup rice\nIngredients (\(note))\n3 tbsp peanut butter\n1 lb shrimp")
        #expect(names.contains { $0.contains("peanut butter") })
        #expect(names.contains("shrimp"))
    }

    @Test(arguments: [("Ingredients (rice, flour)", "flour"), ("Ingredients (peanut, butter)", "butter"),
                      ("Ingredients (gluten-free, except the flour)", "except the flour"),
                      ("Ingredients (nut-free, may contain peanuts)", "may contain peanuts"),
                      ("Ingredients (vegan, contains shrimp paste)", "contains shrimp paste"),
                      ("Ingredients (contains peanuts and tree nuts, may contain shrimp, sesame and soy from the sauce)", "sesame and soy"),
                      ("Ingredients (contains peanuts, 4 star anise)", "contains peanuts"),
                      ("Ingredients (5 stars, contains peanuts)", "contains peanuts")])
    func aHeaderNotesPartsDontCancelEachOther(header: String, part: String) throws {
        let names = try savedNames("Dish\n\(header)\n1 lb beef\n1 cup rice")
        #expect(names.contains { $0.contains(part) && !$0.contains(",") })
    }

    @Test(arguments: ["Ingredients (makes 2 cups peanut sauce)", "Ingredients (serves 4 contains peanuts)"])
    func aNoteThatOpensLikeServingsKeepsItsAllergen(header: String) throws {
        #expect(try savedNames("Dish\n\(header)\n1 lb beef\n1 cup rice").contains { $0.contains("peanut") })
    }

    @Test func aServingsNoteInAHeaderScales() throws {
        let capture = try #require(RecipeTextParser.parseCaption("Dish\nIngredients (serves 2)\n1 lb beef\n1 cup rice"))
        #expect(capture.servings == 2)
        #expect(capture.ingredients.count == 2)
    }

    @Test(arguments: [("Dish\nIngredients:\npeanut butter; shrimp; eggs\n1 lb beef", "shrimp"),
                      ("Dish\nIngredients:\npeanut butter • shrimp • eggs\n1 lb beef", "shrimp"),
                      ("Dish\nIngredients:\nComment PEANUT: peanut butter; shrimp; eggs\n1 lb beef", "shrimp"),
                      ("Dish\nIngredients (vegan; contains shrimp)\n1 lb beef\n1 cup rice", "contains shrimp"),
                      ("Dish\nIngredients (vegan • contains shrimp)\n1 lb beef\n1 cup rice", "contains shrimp"),
                      ("Dish\nIngredients:\n1 cup milk (vegan, contains shrimp)\n1 lb beef", "contains shrimp")])
    func eachSeparatorMakesItsOwnLine(caption: String, part: String) throws {
        let names = try savedNames(caption)
        #expect(names.contains { $0.contains(part) && !$0.contains(";") && !$0.contains("•") && !$0.contains("vegan") })
    }

    @Test(arguments: ["·", " | ", "，", "；", "、", "●", "▪", "◦", "‣"])
    func moreListPunctuationSplitsToo(separator: String) throws {
        let names = try savedNames("Dish\nIngredients:\nvegan butter\(separator)shrimp\n1 lb beef")
        #expect(names.contains("shrimp"))
    }

    @Test(arguments: ["notes", "method", "tips", "nutrition info", "for the sauce", "print", "ingredients", "makes 2 cups peanut sauce", "1. peanuts", "5 stars"])
    func aSplitPieceCantEndTheList(piece: String) throws {
        let names = try savedNames("Dish\nIngredients:\n1 lb beef, \(piece); 2 cups rice\n3 tbsp peanut butter\n1 lb shrimp")
        #expect(names.contains { $0.contains("peanut butter") })
        #expect(names.contains("shrimp"))
        #expect(names.contains("rice"))
    }

    @Test func aBareServingsPieceStillScales() throws {
        let capture = try #require(RecipeTextParser.parseCaption("Dish\nIngredients:\n1 lb beef, serves 2\n1 cup rice"))
        #expect(capture.servings == 2)
    }

    @Test(arguments: [
        ("Dish\nIngredients:\n• 1 lb beef\n• 1 cup rice\n• Tips\n• 2 tbsp peanut butter", "peanut"),
        ("Dish\nIngredients:\n• 1 lb beef\n• Notes\n• 2 tbsp peanut butter\n• 1 cup shrimp", "shrimp"),
        ("Dish\nIngredients:\n• 1 lb beef\n• For the garnish crushed peanuts\n• 1 cup rice", "peanuts"),
        ("Dish\nIngredients:\n• 1 lb beef\n• Makes 2 cups peanut sauce\n• 1 cup rice", "peanut"),
        ("Dish\nIngredients:\n• 1 lb beef\n• Cook 2 cups shrimp first\n• 1 cup rice", "shrimp"),
        ("Dish\nIngredients:\n• 1 lb beef\n• 1 cup rice\n• Method\nMix well\n• 2 tbsp peanut butter", "peanut"),
        ("Dish\nIngredients:\n• 1. Rice\n• 2. Beef\n• 3. Creamy natural peanut butter from the store with no sugar\n• 4. Shrimp", "shrimp"),
        ("Dish\nIngredients:\n• Step 1 peanut butter\n• 2 cups rice\n• 1 lb beef", "peanut"),
        ("Dish\nIngredients:\n1 lb beef; Notes\n2 tbsp peanut butter\n1 cup shrimp", "shrimp"),
        ("Dish\nIngredients:\n1 lb beef • Tips\n2 tbsp peanut butter\n1 cup shrimp", "shrimp"),
        ("Dish\nIngredients:\n1 lb beef; cook 2 cups shrimp first\n1 cup rice", "shrimp"),
        ("Dish\nIngredients:\n1 lb beef; for the garnish crushed peanuts\n1 cup rice", "peanuts"),
    ])
    func aBulletedOrSplitControlWordStaysAnIngredient(caption: String, allergen: String) throws {
        #expect(try savedNames(caption).contains { $0.localizedCaseInsensitiveContains(allergen) })
    }

    @Test(arguments: ["3 tablespoons unsalted butter, cut into small pieces, plus more for the pan",
                      "Kosher salt and freshly ground black pepper, to taste, plus more as needed"])
    func cuttingOnlyHowItsPreparedDoesntWarn(line: String) {
        #expect(!RecipeTextParser.parse(["Dish", "Ingredients:", line, "1 lb beef"]).isTruncated)
    }

    @Test(arguments: ["2 cups dairy free spread from the store near home for the pan, with butter",
                      "2 cups a long blend of toasted grains from the store near home, with dragonfruit",
                      "2 cups a very long blend of toasted grains from the store near our house, minced"])
    func aCutThatMightHideSomethingWarns(line: String) {
        #expect(RecipeTextParser.parse(["Dish", "Ingredients:", line, "1 lb beef"]).isTruncated)
    }

    @Test func aCutThatLosesAnAllergenWarns() {
        let line = "2 cups a long blend of toasted grains from the store near home, with peanuts"
        #expect(RecipeTextParser.parse(["Dish", "Ingredients:", line, "1 lb beef"]).isTruncated)
    }

    @Test func aNameTooLongToKeepSaysSo() throws {
        let long = String(repeating: "mixed roasted nuts ", count: 5) + "peanuts"
        let capture = try #require(RecipeTextParser.parseCaption("Dish\nIngredients:\n\(long)\n1 lb beef"))
        #expect(capture.isTruncated)
        let short = try #require(RecipeTextParser.parseCaption("Dish\nIngredients:\n1 cup rice\n1 lb beef"))
        #expect(!short.isTruncated)
    }

    @Test(arguments: ["plant-based", "plant–based", "plant based", "gluten‑free", "eggless"])
    func aFreeFromLabelHoweverWrittenSplitsALine(label: String) throws {
        #expect(try savedNames("Dish\nIngredients:\n4 \(label) boneless, shrimp tacos\n1 tsp salt").contains("shrimp tacos"))
    }

    @Test func eachPartOfAHeaderNoteIsItsOwnLine() throws {
        let names = try savedNames("Dish\nIngredients (vegan, contains shrimp)\n1 lb beef\n1 cup rice")
        #expect(names.contains { $0.contains("contains shrimp") && !$0.contains("vegan") })
        let long = try savedNames("Dish\nIngredients (a very long note about how this was made at home, contains peanuts)\n1 lb beef\n1 cup rice")
        #expect(long.contains { $0.contains("peanuts") })
    }

    @Test func aHyphenatedFreeFromLabelSplitsALine() throws {
        #expect(try savedNames("Dish\nIngredients:\n4 plant-based boneless, shrimp tacos\n1 tsp salt").contains("shrimp tacos"))
    }

    @Test func everyFreeFromLabelSplitsALine() throws {
        for label in AllergenKeywords.all.flatMap(\.freeFrom) {
            let names = try savedNames("Dish\nIngredients:\n4 \(label) boneless, shrimp tacos\n1 tsp salt")
            #expect(names.contains("shrimp tacos"), "\(label)")
        }
    }

    @Test(arguments: [("Comment PEANUT: 1 cup peanut butter, 2 eggs, 1 cup shrimp", "shrimp"), ("Full recipe in bio: peanut butter, soy sauce, eggs", "eggs"),
                      ("Get the full recipe: 2 tbsp peanut butter, 1 cup shrimp", "shrimp"), ("Link in bio for the peanut sauce", "peanut"),
                      ("Full recipe calls for peanut sauce", "peanut")])
    func aPromotionHoldingIngredientsStays(line: String, allergen: String) throws {
        #expect(try savedNames("Dish\nIngredients:\n\(line)\n1 tsp salt\n1 lb beef").contains { $0.localizedCaseInsensitiveContains(allergen) })
    }

    @Test(arguments: [
        ("Dish\nIngredients:\n1 lb beef\n1 cup rice\n💡 Tip\nFor the sauce:\n3 tbsp peanut butter", "peanut"),
        ("📝 Note\nEasy weeknight dinner.\n👇 INGREDIENTS\n1 cup peanut butter\n2 eggs", "peanut"),
        ("Dish\nIngredients:\n✅ 1. Rice\n✅ 2. Beef\n✅ 3. Salt\n✅ 4. Creamy natural peanut butter from the store with no sugar\n✅ 5. Shrimp", "shrimp"),
        ("Tacos\nIngredients:\n1 lb beef\n🥜 For the garnish crushed peanuts\n1 cup rice", "peanut"),
        ("Tacos\nIngredients:\n1 lb beef\n🥜 Makes 2 cups peanut sauce\n1 cup rice", "peanut"),
        ("Tacos\nIngredients:\n1 lb beef\n🔥 Cook 2 cups shrimp first\n1 cup rice", "shrimp"),
        ("Tacos\nIngredients:\n1 lb beef\n🥜 #1 peanut butter\n1 cup rice", "peanut"),
    ])
    func aDecoratedLineDoesntEndOrHideTheList(caption: String, allergen: String) throws {
        #expect(try savedNames(caption).contains { $0.localizedCaseInsensitiveContains(allergen) })
    }

    @Test func aRecipeRunningIntoAPromotionIsStillARecipe() throws {
        let names = try savedNames("Peanut Noodles\nIngredients: 1 lb noodles, 2 tbsp peanut butter, 1 tbsp soy sauce. Full recipe in my bio!")
        #expect(names.contains { $0.contains("peanut butter") })
    }

    @Test func aPlainListSplitsAroundSubheadsAndNotes() throws {
        #expect(try savedNames("Dish\nIngredients:\nFor the sauce:\npeanut butter, soy sauce, fish sauce").count == 3)
        #expect(try savedNames("Dish\nIngredients:\npeanut butter, soy sauce, fish sauce\nNotes:\nUse crunchy.").count == 3)
        #expect(try savedNames("Dish\nIngredients:\nServes 4\nnoodles, peanut butter, soy sauce").count == 3)
    }

    @Test func aRealStepStartingWithFollowStays() throws {
        let capture = try #require(RecipeTextParser.parseCaption(
            "Dish\nIngredients:\n1 lb beef\n2 cups rice\nDirections:\nFollow the package directions.\nStir in the milk."))
        #expect(capture.steps == ["Follow the package directions.", "Stir in the milk."])
    }

    @Test func keycapsMeanWhatTheirPlaceSays() throws {
        let cooked = try #require(RecipeTextParser.parseCaption(
            "Dish\nIngredients:\n2️⃣ cups milk\n3️⃣ eggs\nDirections:\n1️⃣\nBrown it.\n2️⃣\nServe."))
        #expect(cooked.ingredients.map(\.quantity) == ["2 cups", "3"])
        #expect(cooked.steps == ["Brown it.", "Serve."])
        let titled = try #require(RecipeTextParser.parseCaption("3️⃣ INGREDIENT PEANUT COOKIES\n1 cup peanut butter\n1 cup sugar\n1 egg"))
        #expect(titled.ingredients.count == 3)
    }

    @Test func anIngredientWrittenAsAnEmojiStays() throws {
        let capture = try #require(RecipeTextParser.parseCaption("Dish\nIngredients:\n2 🥚\n1 cup 🥛\n1 lb beef"))
        #expect(capture.ingredients.count == 3)
    }

    @Test func arrowsAreDecoration() throws {
        let capture = try #require(RecipeTextParser.parseCaption("Dish\n→ INGREDIENTS\n→ 1 lb beef\n→ 2 cups rice\nINSTRUCTIONS ↓\nBrown it."))
        #expect(capture.ingredients.compactMap(\.quantity) == ["1 lb", "2 cups"])
        #expect(capture.steps == ["Brown it."])
    }

    @Test(arguments: [("BLT", "BLT"), ("NY STRIP", "NY STRIP"), ("BBQ CHICKEN WITH RICE", "BBQ Chicken with Rice"),
                      ("\"THE BIG TACOS\"", "\"The Big Tacos\""), ("MOM'S CHICKEN POT PIE", "Mom's Chicken Pot Pie")])
    func aShoutedNameIsCalmedCarefully(name: String, expected: String) throws {
        let capture = try #require(RecipeTextParser.parseCaption("\(name)\nIngredients:\n1 lb beef\n2 cups rice"))
        #expect(capture.name == expected)
    }

    @Test func aNameThatIsntShoutingStaysAsItIs() throws {
        let capture = try #require(RecipeTextParser.parseCaption("Mom's BBQ chicken\nIngredients:\n1 lb beef\n2 cups rice"))
        #expect(capture.name == "Mom's BBQ chicken")
    }

    @Test func aCaptionAllOnOneLine() throws {
        let capture = try #require(RecipeTextParser.parseCaption(
            "Ingredients: 1 lb beef, 2 cups rice, peanut sauce Directions: Brown the beef."))
        #expect(capture.ingredients.map(\.name) == ["beef", "rice", "peanut sauce"])
        #expect(capture.steps == ["Brown the beef."])
    }

    @Test func aCaptionWithNoRecipeStaysAnIdea() {
        #expect(RecipeTextParser.parseCaption("Best dinner ever!! So good #yum") == nil)
        #expect(RecipeTextParser.parseCaption("Tag someone who loves tacos\nLink in bio") == nil)
        #expect(RecipeTextParser.parseCaption("") == nil)
    }

    @Test(arguments: ["5,086 likes, 120 comments - cook on June 29, 2023: \"Tacos\nIngredients:\n1 lb beef\n2 cups rice\nDirections:\nBrown it",
                      "120 comments - cook on June 29, 2023: \"Tacos\nIngredients:\n1 lb beef\n2 cups rice\nDirections:\nBrown it.\"."])
    func instagramsWrapperComesOffACutCaptionOrHiddenLikes(page: String) throws {
        let capture = try #require(RecipeTextParser.parseCaption(page))
        #expect(capture.name == "Tacos")
        #expect(capture.ingredients.count == 2)
    }

    @Test func instagramsLikesAndDateArentTheDish() throws {
        let page = "5,086 likes, 120 comments - cook on June 29, 2023: \"Tacos\nIngredients:\n1 lb beef\n2 cups rice\nDirections:\nBrown it.\"."
        let capture = try #require(RecipeTextParser.parseCaption(page))
        #expect(capture.name == "Tacos")
        #expect(capture.ingredients.count == 2)
        #expect(capture.steps == ["Brown it."])
    }

    @Test func nothingReadIsEmpty() {
        #expect(RecipeTextParser.parse([]).isEmpty)
        #expect(RecipeTextParser.parse(["  "]).isEmpty)
    }

    @Test func theDraftScalesToTheFamilyLikeALinkDoes() {
        let capture = RecipeTextParser.parse(["Chili", "Serves 2", "Ingredients", "1 lb beef, ground", "Steps", "1. Brown it."])
        let draft = capture.draft(householdSize: 4)
        #expect(draft.name == "Chili")
        #expect(draft.servings == 4)
        #expect(draft.lines.map(\.name) == ["beef, ground"], "like link import: only long names are shortened")
        #expect(draft.lines.map(\.quantity) == ["2 lb"])
        #expect(draft.stepsText == "Brown it.")
    }

    @Test func theDraftStaysWithinWhatCanBeSaved() throws {
        var capture = RecipeTextParser.Capture(name: String(repeating: "x", count: 200))
        capture.steps = [String(repeating: "y", count: 30_000)]
        let draft = capture.draft(householdSize: 4)
        #expect(throws: Never.self) { _ = try draft.validated() }
    }
}

/// The real thing: Apple's recognizer and PDFKit, on files made here.
@Suite(.serialized)
struct TextRecognizerTests {
    private func pdf(_ text: String?) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "recipe-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        if let text { Self.draw(text, in: context, at: CGPoint(x: 72, y: 600)) }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func draw(_ text: String, in context: CGContext, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: CTFontCreateWithName("Helvetica" as CFString, 36, nil)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    /// A scan: the page holds a picture of the text, not text.
    private func scannedPDF(_ text: String, footer: String? = nil) throws -> URL {
        let picture = try #require(Self.picture(of: text))
        let url = URL.temporaryDirectory.appending(path: "scan-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(picture, in: CGRect(x: 40, y: 400, width: 500, height: 125))
        if let footer {
            let attributes: [NSAttributedString.Key: Any] = [.font: CTFontCreateWithName("Helvetica" as CFString, 8, nil)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: footer, attributes: attributes))
            context.textPosition = CGPoint(x: 40, y: 40)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func picture(of text: String) -> CGImage? {
        guard let context = CGContext(data: nil, width: 800, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 200))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        draw(text, in: context, at: CGPoint(x: 40, y: 80))
        return context.makeImage()
    }

    @Test func aScannedPDFIsReadLikeAPhoto() async throws {
        let url = try scannedPDF("2 cups flour")
        #expect(await TextRecognizer.lines(in: url, type: .pdf).joined().lowercased().contains("flour"))
    }

    @Test func aScannersWatermarkDoesntHideTheScan() async throws {
        let url = try scannedPDF("2 cups flour", footer: "Scanned by CamScanner")
        #expect(await TextRecognizer.lines(in: url, type: .pdf).joined().lowercased().contains("flour"))
    }

    @Test func aHugePageIsRenderedAtABoundedSize() {
        #expect(TextRecognizer.renderScale(for: CGSize(width: 612, height: 792)) == 2)
        let scale = TextRecognizer.renderScale(for: CGSize(width: 7200, height: 14400))
        #expect(14400 * scale <= TextRecognizer.renderLimit)
        #expect(TextRecognizer.renderScale(for: .zero) == 2)
    }

    @Test func aPageWithNonsenseGeometryDoesntCrash() {
        #expect(TextRecognizer.renderSize(for: CGSize(width: CGFloat.infinity, height: 100)) == nil)
        #expect(TextRecognizer.renderSize(for: CGSize(width: CGFloat.nan, height: 100)) == nil)
        #expect(TextRecognizer.renderSize(for: .zero) == nil)
        #expect(TextRecognizer.renderSize(for: CGSize(width: 612, height: 792))?.width == 1224)
    }

    @Test func aPDFsOwnTextIsRead() async throws {
        let url = try pdf("2 cups flour")
        #expect(await TextRecognizer.lines(in: url, type: .pdf).joined().contains("2 cups flour"))
    }

    @Test func aPhotoIsRead() async throws {
        let image = try #require(Self.picture(of: "2 cups flour"))
        #expect(await TextRecognizer.lines(in: image).joined().lowercased().contains("flour"))
    }

    @Test func somethingUnreadableIsEmpty() async throws {
        let url = URL.temporaryDirectory.appending(path: "nope-\(UUID().uuidString).jpg")
        try Data("not an image".utf8).write(to: url)
        #expect(await TextRecognizer.lines(in: url, type: .image).isEmpty)
    }
}
