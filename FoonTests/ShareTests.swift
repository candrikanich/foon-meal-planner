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
