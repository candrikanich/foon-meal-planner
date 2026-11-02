# Family Dinner App — Product Spec

Oct 25, 2026 · @Chris Andrikanich

## Mission

Take the weight of dinner off one person and share it with the whole family.

In most families, one person carries dinner: the weekly plan, the nightly "what's for dinner," the shopping list, and every pivot when schedules change. Others will help, but nobody steps in unprompted. This app makes it easy and expected for everyone to contribute ideas, votes, and feedback, so the planner edits a plan instead of inventing one.

**The app is not** a recipe app, a voting app, or a grocery list app. It closes the loop between them: plan, shop, cook, log, leftovers, plan again.

**Feature filter.** Every feature must pass one test: does it make it easier for more people to contribute, or lighten the planner's load? If yes, it's in. If it's just cool, it waits.

**Week-one success test.** A new household goes from download to a first weekly plan and shopping list in under 15 minutes, with family input already in it. Ongoing: Sunday planning takes about 10 minutes.

**North-star metric.** Family dinners at the table per week. Home cooking is the default (5 to 6 nights for our family); takeout is a tool for crunch nights, not a failure.

## Households and members

One adult buys and sets up the app; one subscription covers the whole household.

**Onboarding (v1, #17).** For the household's owner, right after creating it, and resumed if interrupted: who's at your table (add everyone, kids too); "Does anyone have food allergies?" (No is one tap; Yes shows the one consent sentence and allergen chips plus Other per person); "Which of these does your family make?" (popular first, category tabs, search, Show more; flagged dishes warn but stay selectable; tapped dishes copy into the library); your rhythm (planning day and time, week start, dinner time, notification preset Light, Balanced, or Engaged); invite your family (skippable); then This Week with Build my week up front. "Load a sample family" on the first screen creates a demo household (four members, a kid's milk allergy, ten starter dishes, a planned week) for App Review and the curious; it asks first, since it becomes the person's one household. The onboarding flags are written with the household, in the same transaction, so a closed app still resumes setup. Someone who joins by invite skips the owner's setup.

**Profiles first, accounts second.** During onboarding the owner creates a profile (first name, avatar, adult or kid, parent or not, role) for each family member before anyone installs. Attendance, ratings, and favorites attach to profiles from day one. When a member installs, they claim their profile. Kids without phones still participate via "pass the phone."

**Sign-in.** Sign in with Apple for everyone, including kids on Family Sharing accounts. No passwords; private email relay.

**Invites.** Parents send them by iMessage (the share sheet) with a link plus a code (e.g. SMITH-7KQ4-M9XP: a household prefix and 8 random characters with no look-alikes). iOS doesn't reliably carry link context through an App Store install, so the code is the fallback after sign-in. Codes work once, expire in 7 days, are replaced by a newer invite for the same person, and lock after 5 wrong guesses in 15 minutes. The link is `foon://invite/<code>` until Foon has a domain for universal links.

**Who can do what.** Each person has three separate settings. Who they are (adult or kid, parent or not) is kept apart from what they do in planning (planner or member).

| Setting | Values | What it controls |
| --- | --- | --- |
| Adult or kid | Adult, Kid | Kids get push budgets, school-hours quiet time, parental consent, and no email. |
| Guardian | Parents (adults only) | Manage people (add, invite, set roles, remove), edit everyone's allergies, give or revoke allergy and parental consent. Everyone else sees these but can't change them. |
| Role | Planner, Member | Planner: build and edit the week, manage the meal library. Member: request meals, vote, rate, add to lists, confirm meals; cannot delete dishes or rewrite the plan. |

**Owner** is the guardian who holds the subscription: billing and household settings, plus everything a guardian and planner can do. The owner's profile is always a guardian.

**Rules decided**

- One household per person in v1. Multi-household (split families) is a later feature.
- Parents (guardians) invite; planning rights alone don't include inviting.
- A nanny, grandparent, or roommate is an adult who can be a planner but isn't a guardian. A teen can be a planner too; planning rights never include managing people.
- **Away status** for members who leave temporarily (e.g. college): out of default attendance and notifications, history kept, flip to "home this week" for breaks.
- **Remove from household** (guardians, on member detail): the person's account is unlinked immediately and they lose access; their ratings and cook history stay. Deleting the whole household is separate and does erase data.
- Owner can transfer ownership to another guardian.
- Non-iPhone household members exist as profiles others vote for; a web page may cover them later.

**Family tab.** Header with household name, emoji or photo, Founding Family badge, and subscription status (owner). Member rows show avatar, name, role, and status (Home, Away, Invite pending), with Add member and Invite. Member detail: adult or kid, guardian, and role (guardians edit), Home or Away with optional return date (counts as Home from that date on, by the household's day, in Family, the editor, and the wanted count; the status itself and the heads-up to plan their favorites aren't built), usual weekday schedule and repeating time away (everyone edits their own; guardians can override), eats separately (guardians set it), allergies and dietary preferences (guardians edit; everyone sees), Remove from household (guardians), taste profile of favorites, dislikes, and serving notes (visible to everyone), cook tally, and per-member notification preset. Household rhythm and planning mix defaults, kitchen and food rules (planners), notification presets, show tips again, plain-English privacy summary with data export and delete household, and subscription (owner).

- **Member detail (#47, built):** every row on Family opens it, for everyone in the household. It shows status, age, parent, planning role, eats separately, invite, usual schedule and repeating time away, allergies, taste, and dinners cooked this month. Edit opens the existing editor, for whoever may change something (a kid: their avatar and their own schedule).
  - **Allergies** show only when the person has some, or to a parent, who also gets Add or Change allergies. A family that answered No doesn't see them otherwise. Adding uses onboarding's chips and its one sentence: the sentence shows whenever the answer has anything in it, and Agree and save records the consent. Taking the last one away asks for nothing. The list is read fresh on opening and again before saving, and only what this parent added or took away changes, so another parent's addition or removal stays. If it can't be read, nothing can be saved. Other is one entry whatever its capitals: "kiwi" and "Kiwi" save once.
  - **Reaching other phones:** This Week re-reads allergies, the dishes, and who's in the family with reactions whenever it comes back, when the family changes, and before Build my week, so a new allergy, a new or removed member, or an edit to a dish's ingredients reaches the cards without a visit to Library. Allergies flag and never filter, so Build's pick doesn't change; its card does. A profile that couldn't refresh says what it shows may be out of date.
  - **Saves that overlap:** the member editor sends only what changed since that sheet opened, not since the last refresh, so it can't undo a schedule or status someone else just set. A refused save says what's known: 42501 is "a parent, or the household's owner, can make it"; PGRST116 is "couldn't find that profile, or you no longer have access."
  - **Taste** is read-only and about dishes: Favorites, Would rather skip (not for me), and How they like it served. Archived dishes are left out. Tired of it is left out, since it's a snooze that wears off.
  - **Cook tally** is this month's dinners and thank-yous, the same as the Family list. There's no row at zero: it's credit, so nobody's profile says they didn't cook.
- **Rhythm and planning mix (#47, built):** Family → Rhythm and planning mix, planners only, the same rule as the server's. It's onboarding's rhythm form plus the mix (new dishes, takeout nights, leftover nights, days before a repeat), and saves only the keys changed since it opened, so a stale phone, or a refresh while it's open, can't undo another planner's change. Changing dinner time moves tonight and every later night (see Household planning settings); the mix applies the next time Build my week runs.
  - **Week start:** can't change while a plan is running or waiting (the latest plan's last night is today or later, by the household's day), or when Foon can't read the plans. This Week finds a plan by the day it starts, so moving the start would hide a running plan's dinners and let another start over the same nights. The check runs when the screen opens and again on save, on the device only.
    - **Its weaknesses, known and accepted for now:** a family that always starts next week early rarely gets a window to change it. After a change, the new week can begin on days already behind you, which show as blank Earlier cards beside the old plan's. Two planners racing can still get past the check.
- **Notification presets on Rhythm:** the household preset, saying what each sends today and what's on the way. Family also says whether reminders are on for this device. Per-member presets and overrides, and ignore handling (downshift to a weekly roundup, the gentle re-enable prompt) wait for M2 car 6, because they need `notification_log` and its settings.
- **What Foon keeps (#47, built):** the privacy summary, for everyone, next to export and delete in Your data: what's kept, what stays on the device, what leaves it, who sees what, and how to change your mind. "Removes it from Foon" describes what the app does; how long a hosted backup keeps deleted data is for the privacy notice and legal review. Each line has to be true of the code today, so a change to what the app collects or sends changes that screen in the same PR (analytics and crash reporting aren't in the app yet; when they land, "no tracking" needs another look). It isn't the privacy policy (#67) and claims no law.

**Minimal data.** Household name (last name or nickname), first names, avatars. No birthdays, phone numbers, photos, or location, apart from the household's time zone (decided 2026-10-28). That's coarse, needed to know when last night's dinner was, and disclosed in the privacy notice. Keep the app a parent-run household app, not in the App Store Kids category. COPPA applies if users under 13 are known; get a legal review before launch.

**Allergies and dietary preferences**

Important, never a burden. Families without allergies don't see allergy UI, with one exception: when this phone couldn't read the library or the allergies, it can't know what the family's allergies are now, so a card or list says so. A dish it can't find says it couldn't check (see "A dish Foon can't look up"), and a dish it can find keeps what it last read and says "Allergies may be out of date", which can mean every dish card while offline, because a new member's allergy could be the one missing. Families with allergies tell the app in about 30 seconds.

- **One question in onboarding:** "Does anyone have food allergies?" No is one tap and the topic doesn't come back as a question (the one note a family with none can see is when a load fails; see "A dish Foon can't look up"). Yes opens one screen: a single plain sentence ("Foon keeps these with your household so it can flag dishes. They're never sold, never used for ads, and never leave your devices for AI. Parents can delete them anytime.") above each person with tappable chips. The screen's one button, Agree and save, is the opt-in; there is no separate consent step. (Wording pending legal review.)
- Standard chips: the 9 major US allergens (milk, eggs, fish, shellfish, tree nuts, peanuts, wheat, soy, sesame) plus Other with free text. Each maps to a keyword list (casein and butter map to milk, tahini to sesame).
- Guardians add and change allergies later from member detail, using the same chips. Everyone in the household sees them.
- **Flag, don't filter:** affected dishes (starter pack included) stay available with a flag such as "Contains milk (Nora)." Flags show in the library, on day cards, in Swap and Plan it before a dish is chosen, and on the shopping list ("Cheese: get dairy-free"). Planning is never blocked by an allergy, and allergies never trigger push notifications.
- **No ingredients, no check (#155):** flags read a dish's ingredients, so a dish with none can't be flagged, and no flag mustn't read as safe. Wherever flags show (library tile and VoiceOver, meal detail, day cards, the freezer stash, Swap, and Plan it) it says "No ingredients yet, so allergies can't be checked" instead. Flags count sides, so a dish whose side is a library dish with no ingredients says "No ingredients for Cornbread yet, so allergies can't be checked", and one whose side isn't in the loaded library says "Couldn't find a side for this dish, so allergies can't be checked" (#185). A retired side isn't served, so it drops off and says nothing. The library reads in pages, so a household past the server's 1000-row cap still gets every dish, along with each dish's history, likes and everyone's verdicts (#189); a side should only go missing briefly, when another phone is changing dishes during a read. Meal detail looks sides up in the whole library, like the tile: it flags what's in a side, which it used to miss. It's said only when someone has allergies recorded (on a night's card, someone home that night), so a family with none never sees it. Every path to a night reads the same card: Build, Swap, Plan it, a freezer night, and a leftovers night that knows its dish. A quick pick names no dish and says nothing. It isn't a flag: those dishes stay out of the Allergy flags filter, which says how many meals can't be fully checked whenever there are any, flagged dishes or not. The shopping list flags item by item, so it can't say what's missing: a dish with no ingredients adds only its sides, and a side with none adds nothing.
- **Flags before choosing (#157):** Swap (Suggestions, Your meals, held back by food rules, the freezer, Foon's ideas, and Restore) and Plan it show a dish's flags and its no-ingredients note before it's chosen, by the card's own rule: the same function, for whoever's marked home that night (someone who eats separately counts, a removed member doesn't), sides included. Someone with allergies and no attendance row that night (added after the week was made) counts as home for allergies, on cards, in Swap and Plan it, on freezer offers, and in the list's notes, since nobody's said they're out; only being marked out takes them off. Serving notes and jobs still go by who's marked home. The list's notes count whoever's home for the dish or for its leftovers night, linked or the night after a big batch, the same as that night's card. Plan it lists several nights for one dish, so each night says its own. Flags never hide or block a dish.
- **A dish Foon can't look up (#157):** a card holding a dish the library can't find, including a freezer night, leftovers linked to it, and leftovers the night after it (only the library can say that dish was a big batch), says "Couldn't check this one for allergies. Pull down to try again." and pulling down reads the library again. While a load is running or hasn't started, it says nothing and waits for the answer, so there's no false warning. A load that ends with no answer, failed or cancelled, says it. If the last load failed, the family's allergies are unknown or may be out of date, so it says it to everyone, even a family with none recorded: that's the one time they'd see this. A dish it can still find keeps the flags from the last read and says "Allergies may be out of date. Pull down to try again.", on its card, in Swap, and in Plan it. So does a refresh that couldn't read the allergies (reactions failing alone doesn't count), since someone's allergy may be what's missing; pulling down does a full load, and the note stays until its answer is applied, while a dish it can't find waits for that answer. If the last load worked and the library is just missing the dish (another phone just planned it), it's said only when someone home has allergies recorded. Plan it says the same when the library couldn't be read, since it has the dish but not its sides or the allergies.
- **Leftovers that name no dish say nothing (#157):** leftovers someone picked by hand after a known dish that isn't tagged a big batch stay silent, on the card and the list, because Foon doesn't know what's in them. So do Build's fallback leftovers night on a rushed night and leftovers after a quick pick. This silence is a known limit, not a check.
- **Turning allergy alerts off** (Family settings, guardians) erases the household's allergy data.
- Later, not v1: a substitution table and "Make it safe" button that create the family's own version; a library review prompt when an allergy is added.
- Presented as a helper, not a guarantee. UI and terms say families still check labels.
- Household-only visibility, never sent off-device, disclosed in the App Store privacy label.
- Dietary preferences (vegetarian, no pork) use the same mechanism as soft warnings.

## Meal library and ideas

The library is the foundation; adding, editing, and removing meals must be nearly frictionless.

**Starter pack.** About 50 common family dinners (tacos, spaghetti, grilled chicken, breakfast-for-dinner), each pre-tagged with ingredients, effort, and prep steps. Onboarding: tap the ones you make, and the library is seeded in about 3 minutes. Untapped dishes never enter the library.

Full starter list with categories and tags: [Starter Pack](starter-pack.md)

**Catalog vs library.** The starter pack is a shared, read-only catalog we maintain and grow through updates. The family library holds the household's own meals and is what planning draws from. Onboarding asks "Which of these does your family make?" and copies each tapped dish into the library as an editable version (rename, tweak, own photo). Favorites come later from ratings. After onboarding the catalog stays browsable (Library, Add, Browse ideas), appears below the family's dishes in search, and feeds the optional "try something new" slot, filtered by allergies and effort. The algorithm never fills a week from the catalog except through that slot.

**Meal imagery.** Photos first, icons as backup. Starter pack: about 50 AI-generated photos made once before launch with a shared style prompt (overhead, warm light, square crop) via an image service, checked for commercial-use terms, and bundled with the app; free-license stock photos fill any gaps. Apple's on-device Image Playground is for stylized illustrations, so it is only used for fallback tiles on capable devices. Family meals: the imported recipe's photo, then an optional family photo (prompted after a dish is first cooked: "Snap your version?"), labeled "Made by" ("Dad's tacos") and shown everywhere the dish appears, then an auto-composed tile of ingredient icons (spaghetti, meatballs, tomato, bread) on a warm background, built from a mapped icon set.

**Each meal carries**

- Name, ingredients (quantities optional), original serving count
- Effort tags: quick (under 30 min), needs grill, needs advance prep, morning start (slow cooker), beginner-friendly
- Prep steps with lead times: thaw (24 h), marinate (4 h or overnight), slow cooker start (8 h before dinner), chop ahead
- History: last made, per-person reactions, comments, who cooked

**Adding a meal**

1. **Quick add:** type a name and save. Ingredients optional; an "add ingredients" badge reminds later. Ingredients typed naturally ("1 lb ground beef, taco shells, cheese") are split into items, with autocomplete from past items. (v1: Library → Add → Quick add, for planners; autocomplete offers the household's items for the ingredient being typed, keeping its amount; the new meal opens when added.)
2. **Copy and tweak:** duplicate a starter dish ("Tacos" to "Our tacos") and edit.
3. **From a link:** recipe websites parse via embedded schema.org recipe data.
   v1 (#21): Library → Add → From a link, for planners.
   - **Reading the page:** the import-recipe Edge Function fetches the page and reads its JSON-LD Recipe: name, servings, ingredients, steps, and image URL.
   - **Preview:** before adding, the app shows the recipe scaled from the recipe's servings to the family's size (amounts like "1 1/2 cups" scale; "to taste" doesn't), with the link kept as the source.
   - **No recipe data:** the page title and link are saved, and the preview says there was no recipe card.
   - **Page can't be read:** if it's down, or the site turns Foon away, "Save just the link" keeps the link, and the preview says Foon couldn't read the page rather than that it has no recipe.
   - **From an idea (#155):** Save to library on an idea with a link opens this same screen, read at once. The idea's own name, when it has one, goes on the dish in every case (the planner can change it); with no name, the recipe's or page's name does. A social post with no recipe card uses the recipe in its caption, the same read as the share sheet, so an idea saved from a post can become the whole dish later. A caption is a guess, so here the ingredients can be swiped away, and "Keep just the name and link" drops what was read.
   - **Safety:** the function opens only public web pages, by name (IP-literal IPv6 hosts are refused). Private, loopback, link-local and mapped addresses are refused on the resolved addresses and on every redirect, with a 2 MB cap and a 10 s limit. The fetch resolves the name again, so a DNS server that answers differently the second time (rebinding) isn't caught; the platform's egress rules are the backstop. Only signed-in people can call it; the app's anon key isn't enough. It says honestly that it's Foon and doesn't try to get past sites that block apps.
   - **Images:** not saved, because recipe photos belong to their sites; families add their own.
4. **From a photo, screenshot, or PDF:** text recognition, then ingredient parsing (AI on capable devices).

**Share Sheet extension (v1).** One share target for everything: recipe links and videos go to the library or idea inbox, screenshots to recipe capture, PDFs to import, plain text ("milk, eggs, bread") to the quick shopping list. Social posts (Instagram, TikTok, Facebook) fall back in order: parse the caption, then a screenshot of the ingredients, then save as an idea with title and link.
- v1 links and text (#39, part 1). The extension only saves: no network and no sign-in, because extensions get little memory and time and everything that can fail belongs in the app. It writes the item to a folder shared with the app (the App Group `group.com.andrikanich.foon`), says "Saved. Open Foon to finish.", and closes. Text with one web link in it ("Great chili https://...") counts as that link, titled by the rest. When Foon is open, past onboarding, a banner at the top of each tab says something's waiting; a banner rather than a sheet of its own, so it never interrupts store mode or cook mode. Tapping it opens each item, oldest first:
  - **Recipe link:** Add to our meals (planners; Link import, read at once) or Save as an idea, with an editable title.
  - **Social post** (Instagram, TikTok, Facebook, YouTube, Pinterest, Threads, X): Save as an idea with its title and link. For planners, Foon also reads the page's caption (the same read as adding a link, part 3); if it holds a recipe, at least two ingredients, the review screen below appears with Add to our meals, and its Meal name becomes the one name on the screen (emoji off the ends of its lines, a name in capitals calmed down, and "comment for the recipe" lines dropped): the shared title or what someone typed, else the caption's first short line, a guess they can edit. Save as an idea keeps that name and the link, not the ingredients and steps; the screen says so, and Save to library on the idea reads them again from the post. If the site turns Foon away that later time, the idea still has its name and link. Many social sites turn apps away, and many posts have no recipe in the caption (they point to a video or a link in bio); then it's just the idea, and the screen says Foon couldn't find a recipe, which covers both without blaming anyone. Instagram often sends only the link, so the title comes from that same read, filling the field only if it's still empty. A page that only names its site or asks for a sign-in gives no title, and a post with no title is called "Instagram post" (or TikTok, and so on) rather than by its address. The link you can tap on the share screen always shows its real address too ("Instagram post · instagram.com").
  - **Text:** the items, ready to remove any, then Add to the quick list (the same rules as the Lists screen; known items work offline, new ones need a connection).
  - **Not now** brings it back the next time Foon launches, and **Discard** drops it. Signing out clears what's waiting on the device, and another account signing in never sees it. Something shared while signed out waits for whoever signs in next, and what's waiting survives deleting a household (it's still that person's). `SharedInbox.claim` holds the rule. At most 50 can wait; a full inbox says so in the share sheet.
  - Only web links are accepted, so a file address or another app's link can't come through. iPhone and iPad only: the Mac has no share extension yet.
- v1 photos and PDFs (#39, part 2). The extension also takes a photo, screenshot, or PDF (the first, if several are shared): a photo is scaled down (2400 pixels at most) and a PDF up to 25 MB is copied, both beside the waiting item. Foon reads it on the device only (Apple's text recognition; a PDF's own text when it has some, up to 10 pages) and never uploads it. Then it shows what it found, all editable, because photos read imperfectly and allergy flags read these ingredients: the name, the ingredients (scaled to the family, like a link), and the steps. Then **Add to our meals** (planners), **Add to the quick list** (for a photo of a shopping list), or **Save as an idea** (just the name).
  - **Reading is plain code** (`RecipeTextParser`), no AI. It looks for Ingredients and Directions headers, otherwise for lines starting with an amount or a bullet. When unsure it keeps a line as an ingredient, since a wrong ingredient is easy to delete and a missing one misses an allergy flag. A list of short lines with no amounts is a shopping list. Screen chrome (the clock, site names, ratings, prep times), ads, and page numbers are dropped, and Notes or Nutrition end the recipe: Foon never keeps nutrition.
  - **The file** is deleted when the item is handled or discarded, and everything waiting goes on sign-out. Waiting files are left out of device backups. A PDF's huge declared page is read at a bounded size, and one locked with a password says so.

**Quantities.** Recipes scale once, at import, to household size. Short-handed nights don't rescale; they predict leftovers instead. Per-night scaling of weight-based items (meat, produce) is a later option. Household size updates automatically with away status. The one exception is Double it (see Cook once, eat twice), which doubles a night's amounts on the list, and says so.

**Removing.** Swipe to archive: gone from suggestions, recoverable, history kept. Dislike rules retire dishes automatically.

- **Deleting an unused dish (#168, decided 2026-10-31):** the one thing that's hard-deleted, so a mistaken import doesn't sit under Archived forever. Planners get Delete, after a confirmation, on the dish screen and the Library long-press, only for a dish nothing depends on: never on a plan night or in the plan's change history, no dinner logged (ratings hang off those), not a tradition, not another dish's side, no serving note, nothing in the freezer. Everything else can only be archived. The server checks again and makes the delete in one step, so a dish planned on another phone a moment earlier is refused with a message.
- **What goes with it:** its ingredient lines, its own side list, and its photo. The app removes the photo after the delete, so a failure there can leave an unreachable file in Storage. The household keeps the items.
- **An idea linked to it** stays, with its name and link (taking the dish's name if it had none). A planned one goes back to waiting; an archived or special-occasion one stays as it is.

**Library screen.** Search, a prominent Add button (quick add, link, photo, paste), filter chips (Favorites, Quick, Trying, Backup dinners, Allergy flags, Archived), a two-column photo grid with effort, made-by, and allergy indicators, and sorts (Haven't had in a while, Most made, Family favorites, Recently added).

- Filters are one at a time; with none chosen, the grid shows meals in rotation (active and trying). Archived also lists retired dishes.
- Search matches meal names and ingredients, ignoring case and accents. Matching starter dishes not yet in the library appear below the family's own ("From Foon's ideas").
- History (times made, last made) counts logged dinners: confirmed, or saved overnight unanswered (#42). A past night of an approved plan with no log (from before logs existed) still counts. Haven't had in a while puts never-made dishes last; they're new, not forgotten.
- Favorites shows dishes that are someone's favorite now (their latest reaction). Family favorites sorts by how many people's favorite a dish is, then by how often anyone rated it Favorite or Good (#42).
- Long-press: Plan it and Archive, or Back in rotation for archived meals, plus Delete for a dish that's never been used (planners only).
- Browse ideas lists the catalog by category; planners copy a dish into the library with one tap, and adding it again returns the copy already there, even a retired one: a dish the dislike rule retired stays retired until a planner brings it back.

**Meal detail.** Hero photo with "Replace with yours"; tags and allergy flags (Make it safe comes later; see Allergies); every family member's current verdict, visible to all; history and frequency ("Made 8 times, about every 2 weeks"); editable ingredients with Add to list; optional recipe steps and source link; prep steps; comments; per-person serving notes ("Nora: keep everything separate before mixing"), shown on day cards and in cook mode when that person is home; actions Plan it, Copy and tweak, Archive, and Delete for a dish that's never been used.

- v1 (#19): ingredients are edited as lines (amount and name), typed or pasted naturally with autocomplete from the library. New items take the starter pack's category for the same name, else Other. Saving writes the meal and its lines together.
- Add to list puts an ingredient (or all of them) on the quick list; anyone in the family can, offline too.
- Copy and tweak makes "Name (copy)" with the recipe, prep, and ingredients, but not the photo or the catalog link, and opens the editor on it. Retired meals aren't copied, so the dislike rule holds.
- Steps are optional, one per line; typed numbering ("1.", "Step 2:") is dropped. Links must be web addresses; "example.com" gains https.
- "What everyone thinks" shows each family member's current verdict (their latest reaction to the dish), visible to all (#42). Frequency ("about every 2 weeks") comes later.
- **Comments (#49, #149):** meal detail lists what people said about the dish, for everyone in the family. They come from the after-dinner comment card (see Prompt design). A planner can hide a comment or show it again; see Hiding a comment.
- v1 serving notes (#46, part 2):
  - **What:** one note per person per dish, up to 120 characters ("Nora: keep everything separate before mixing"), visible to the whole family.
  - **Who writes:** you write your own; parents write anyone's, kids without phones included. Tapping a note edits it, Add a serving note picks the person, and clearing a note deletes it (it's a current preference like an allergy row, not history: the one kind of family input that's deleted, not kept). Length is counted as the server does, so emoji count fairly.
  - **Where:** on day cards, under the dish (and in the card's VoiceOver summary), for people home that night, in family order. Cook mode shows them too (#46, part 3). This Week re-reads notes with reactions on each load.
  - **Retention:** deleting an adult's account or anonymizing a removed kid deletes their notes; a withdrawn kid's self-written notes are erased.
  - **This Week** now loads the library for everyone, not only planners, so members see allergy badges and serving notes on the cards too.
- v1 Plan it (#18, #19), planners, from the long-press menu and meal detail: pick a night from tonight on in the week This Week shows (each row says what it holds now; nights already set to this meal are left out). Like Swap, it replaces the night and locks it, so Rebuild keeps it. With no week yet, it points to This Week.

**Frequency awareness.** Overuse nudges ("Tacos 3 times in 2 weeks"), neglect nudges ("No pot roast in 7 weeks"), and recap callouts make the log the planner's memory.

**Cook mode (Phase 2).** One step per screen, timers, screen stays awake, serving notes surfaced; supports beginner cooks.
- v1 (#46, part 3): **Start cooking** on meal detail, for any dish with steps. Full screen on iPhone, a sheet on Mac.
  - **Before you start:** serving notes (titled Tonight, for who's home, when it's tonight's dish; else everyone's), and the ingredients with amounts. Arrow keys page on a Mac.
  - **Steps:** one per page in big type; swipe or Back and Next on iPhone; All done at the end.
  - **Timers:** times found in a step ("simmer 30 minutes", "bake 1 1/2 hours", "rest 20-25 min", which starts at the low end) become one-tap timer buttons. Running timers count down at the bottom. "1 hour 30 minutes" is one timer, and "45 min-1 hour" starts at 45 minutes. Each schedules a local notification ("Timer done: 30 minutes. Time to check on chili."), so it goes off with the phone locked, and it shows with sound while Foon is open too. Stopping a timer or leaving cook mode cancels its alert. Foon asks for notification permission the first time a timer starts; with alerts off, cook mode says to keep Foon open and links to Settings.
  - **Screen:** kept awake while cook mode is open, on iPhone, iPad, and Mac.

**Idea inbox.** Anyone can request a dish. Dated requests ("steak Friday, my night off") land on that week's plan; "someday" wishes sit in a backlog the planner pulls from. New dishes start tagged as trials until everyone has reacted.

**Ideas tab.** Sections: For this week (dated), Someday, New finds (shared recipes processing or awaiting review). Cards show requester, photo or link preview, note, +1s from others ("me too"), and status (Waiting, Planned for Friday, Tried). One "I want..." button: pick from library, share or paste a link, snap a photo, or type freely, with an optional night.

**Inbox rules.** No hard decline and no request limits. Planner actions: Plan it, Save to library, Not this week (carries forward), and Save for a special occasion (resurfaces on birthday or celebration nights: "He's wanted crab legs since March"); plain archive for clutter. Unplanned dated requests move to Someday. Requests with multiple +1s get top priority in Build my week, on a night everyone who wants it is home. Requesters are notified when their idea makes the plan.

**v1 requests (#38, part 1, data).**
- **What a request is:** a library dish, a typed name (up to 80 characters), or a web link, with an optional note (up to 200) and an optional night from today on.
- **Who asks:** you, or (pass the phone) a profile nobody has claimed. **Me too** follows the same rule. It's a vote, so it can be taken back, and not on your own request.
- **What happens next:** planners plan it (on a night), save it for a special occasion, move it to Someday (Not this week clears the date), archive it, or link it to a library dish (Save to library). The person who asked (or whoever entered it on their phone) can change the note or night, or archive it; once it's planned, only a planner moves it. Nothing is deleted.
- **Sections and status:**
  - For this week: dated this week, or planned on one of its nights, in night order.
  - Later: dated or planned for a later week.
  - Someday: no date, a night gone by without being planned, or saved for a special occasion. Most me-toos first, then oldest.
  - A request planned in an earlier week is Tried and leaves the board.
  - New finds: links not yet turned into a library dish.
  - Status reads Waiting, Planned for Friday, Tried (its planned night has passed), or Special occasion.
- **Planning:** an open, dated request for a library dish this week lands on its night in Build my week (already a kept night; see Weekly planning).
- **Retention:** deleting an adult's account clears their notes on requests, as does anonymizing a removed kid. A withdrawn kid's own requests and me-toos are erased.

**v1 Ideas tab (#38, part 2).**
- **The tab:** For this week, Later, Someday, and New finds. Each row shows the dish (or name, or link's site), who asked and for which night, the note, me-toos, and its status. A hand button says **Me too**, or takes it back.
- **I want...:** from our meals (searchable), name it, or a link (it waits in New finds), with an optional note and night. With someone home who has no account of their own, it asks who wants it (pass the phone). Photo requests come later.
- **Tapping an idea** opens it.
  - Planners get: Plan it (picks a night like Plan it in the library, then marks the idea planned there; if marking fails, the sheet stays open to try again), Save to library (a link opens From a link, read at once, to check before adding; a name makes the dish as it is; either way it links the dish and goes straight to Plan it. It reads the idea again first, since ideas have no realtime: one another phone has saved shows its dish instead. If linking fails, the same dish is remembered while the app stays open, so trying again, even after closing the idea, links it and never makes a second one. An idea keeps its dish: the server refuses a different one and says so, and the same one again is fine. If the dish doesn't load, the idea offers to try again, and pulling down on Ideas reloads the library when an idea's dish is missing from it), Not this week (for an open idea with a night ahead), Save for a special occasion (or Back to Someday, which clears its night), and Archive.
  - The person who asked, or whoever entered it on their phone, gets Archive (while the person it's from is them or still has no account of their own: the server's rule).
- **Build my week:** a dated request lands on its night saved locked, so a Rebuild keeps it, and the idea is marked planned there. After any Build, Fill, or swap, a planned idea whose night no longer holds its dish goes back to open. Build from the empty state uses dated requests too.
- **This Week:** the empty state shows "3 requests waiting" (opens Ideas) for everyone.

**v1 priority and news (#38, part 3).**
- **Priority:** a someday request for a library dish (or one whose date went by) that three people want, the requester and their me-toos, gets top priority in Build my week. Only members at home, going by their return date on the household's day, count (not removed ones, nor anyone away, who couldn't be home for it, nor anyone who eats separately, who can still say me too but doesn't count toward it), and a family of two needs both. Most wanted first, then the oldest; it lands, saved locked, on the first open night everyone who wants it is home, after dated requests and traditions. With no such night, it waits for another week (it can still come up as an ordinary pick). A food rule moves it to a night the rule doesn't apply to, if there's one (see Food rules).
- **Marking it planned:** only that idea, on the night Build placed it, never a tradition, another night that happens to hold the same dish, or another idea for the same dish.
- **Not this week** (for a dated idea still ahead, or a dish that would get priority) sends it back to Someday and keeps it out of the current week's priority (even when This Week is showing next week); it comes back the week after. Swapping a priority dish off its night does the same, so a Rebuild doesn't bring it straight back. The server keeps the week (`requests.skipped_week`); only planners set it.
- **News:** whoever asked (or whoever entered it on their phone) sees "Your idea made Friday: Crab legs" ("is on for tonight" or "tomorrow") at the top of This Week, for a night within the coming week (today and the seven nights after), until the night or until they dismiss it on that device. Push comes with notifications (M2 car 6).

## Weekly planning

The planner taps "Build my week," gets a solid draft, and shapes it. The algorithm is plain code and works on every device; AI is an optional layer.

**Household planning settings.** Planning day and time (ours: Sunday morning, before shopping), week start (the shopping day), new dishes per week, takeout nights, leftover nights, minimum days before a repeat (e.g. 10), dinner time per night. Each night keeps its own dinner time from when its week was made. Changing the household's moves tonight and every later night, in weeks already started too (#170); past nights keep theirs, since their prompts and logs used it. Nothing sets one night's time yet.

- Stored in `households.settings` (#22), every key optional with a default: `week_start` (ISO weekday, default 7 = Sunday), `dinner_time` ("18:00"), `new_dishes_per_week` (1), `takeout_nights` (0), `leftover_nights` (1), `repeat_window_days` (10). Out-of-range values fall back to the default. Planners change them after onboarding in Family → Rhythm and planning mix (see Family tab).

**Attendance per night.** Each night has a checklist of who's expected home, pre-filled from per-person recurring defaults ("Owen works Mon to Thu") and edited for exceptions. Planners own attendance; real-life changes happen by text and get reconciled by the day-of check-in and the after-dinner prompt.

- v1 (#22): `members.attendance_defaults` is `{"usually_away": [ISO weekdays]}`, set on the member's profile ("Usually home for dinner"; everyone edits their own, parents anyone's). Starting a week (`create_week`) makes seven nights from the shopping day at normal effort and the household dinner time, with a row for everyone not removed: out on their usual nights away, and away members out until their return date (all week without one). Someone added later gets their nights filled in when a planner next opens the week. A week starts on the shopping day; a dinner time that isn't HH:MM falls back to 18:00. Tapping an avatar toggles it; tapping the effort chip cycles normal, rushed, full evening, event.

- **Away dates (#52):** a planner marks when the whole household is away, in Family → Trips and seasons (first and last night, both included, up to a year at a time; dates that overlap or run on from each other become one stretch). The confirmation shows the dates, with the year if it isn't this one, how many nights, and what comes off. "Today" is the household's day, wherever the device is. An older household with no saved time zone gets the device's zone from the first planner's device to load it; until then each device goes by its own day, not the server's New York fallback.
  - **The nights:** from tomorrow on, everyone's out and anything planned comes off, locked nights included, and isn't restored. A request planned for one of those nights goes back to open. Tonight keeps a dinner it already has, since it may be eaten by now, and still reads as itself; a planner leaving before it swaps it off, and then it's like the other away nights, with everyone out. Tonight with nothing planned counts as away. Past nights and dinners logged don't change.
  - **On This Week:** everyone sees a note with the dates, and those nights' cards just say Away, with nothing to tap. A week with no nights left outside the dates, not yet started, says you're away instead of offering Build my week.
  - **Planning:** Build my week, Fill, Shuffle, and Plan it skip those nights (no dated requests or traditions land on them), and they don't count as open nights. The server refuses a new dinner on an away night from any device, including one that hasn't heard about the dates or an older app's Swap; the app says the family's away and reloads the household, so it learns the dates. Past nights can still be corrected, and tonight's dinner changed if it has one. I want... won't send a request dated for an away night, and an idea doesn't count as landed on one.
  - **Lists:** the weekly list leaves them out, and with nothing planned there's nothing to approve. Marking dates never removes list lines, because a line can belong to another week, be a staple, or have someone's own note merged in; the confirmation says the list keeps what's on it until someone taps Update the list. An approved week with nights still ahead offers Update the list, even when no dinner is left and even after the dates end. The quick list stays open for anything added by hand.
  - **Ending early:** removing a stretch, or part of one, puts usual schedules back on its nights from today on. They're empty until someone plans them.
  - **Stored:** `households.settings.away_dates` (`[{"from", "to"}]`), changed only by `add_away_dates` and `remove_away_dates`. Those merge into the list on the server under a lock on the household, so a device with an old copy can't undo another planner's dates. A trigger on `households` enforces it: a direct edit or settings save keeps the dates as they are, and a new household can't start with any. Up to 40 stretches can be added; removing always works. Devices reload the household quietly when the app comes back to the foreground: offline, nothing changes and no error shows. Older apps see those nights as Nobody's home.
- **Repeating time away (#49):** for shared custody and the like, a member's schedule can repeat: every other week, every three or four weeks, the whole week or Friday to Sunday, from a first night away. Each week is the seven nights from that first night, so a handoff can fall midweek, and nothing's away before it. Friday to Sunday asks for the first weekend instead, and counts from that weekend's Friday whichever day is picked, so a weekend started on its Saturday isn't split. Whoever can edit someone's usual days can edit this: themselves, or a parent. Like the usual days, it fills in each new week and leaves weeks already started alone. Stored in `members.attendance_defaults.away_pattern` (`{"every_weeks": 2, "from": "2026-11-02", "days": [5, 6, 7]}`, no days meaning all). A saved schedule keeps it with the rest. From the app, that column merges by key: a key left out stays, null takes any key away. So an older app saving the usual days, or a phone with an old copy, can't undo a pattern. A hand-written value that isn't exactly that shape is no pattern, on the server and in the app alike: it never puts anyone away.
- **Saved schedules (#52):** a parent saves everyone's usual nights home under a name ("School year," "Baseball season," "Summer") and switches between them, in Family → Trips and seasons.
  - **Saving:** copies each member's usual schedule as it is on the server right then. Using a name again, whatever the capitals, replaces that one, after a confirmation. The name is up to 40 characters.
  - **Switching:** sets each saved member's usual schedule, for weeks started from then on; weeks already started don't change. Someone added since keeps their own. If today's schedule isn't saved anywhere, the confirmation says so. The one already in use shows a check.
  - **Who:** parents save, switch, and delete, the same rule as changing someone else's usual schedule by hand. Everyone in the household can read them on the server, but only parents see the screen.
  - **Stored:** `attendance_templates`. Deleting a saved schedule, after a confirmation, removes it. A person's copy leaves every template when they're removed from the family, which deleting an account and retention both go through. It's included in the export.

**Night effort.** Each night is set to full evening, normal, or rushed. Rushed nights only get quick meals, takeout, or leftovers.

**Build my week algorithm**

1. **Lock** what's decided: dated requests, event nights, pinned meals, standing traditions, then someday requests several people want (on a night they're all home).
2. **Fill special slots:** leftover night after a big-batch meal; takeout on the busiest night; new dishes on full-attendance nights.
3. **Filter candidates per night:** drop dishes inside the repeat window or snoozed; dishes disliked by anyone home that night; retired dishes; non-quick meals on rushed nights; grill or advance-prep meals where they don't fit.
4. **Score and draw** with weighted randomness: days since last made (higher is better), a favorite of someone home (big boost), ingredients already on hand (boost), overall thumbs-up (small boost), in season for that night (boost), a category already in the week (lower).
5. **Planner edits:** swap, lock, shuffle any unlocked night, approve. Approval generates the weekly shopping list.

v1 rules (#24, `Foon/Core/Planning/BuildMyWeek.swift`, a pure function of the inputs and a seed):

- **Kept nights** (never changed): locked, event, nights before today, and a dated request's night. Requests skip the filters because the family asked out loud. Kept nights count toward the takeout, leftovers, and new-dish settings, so a mid-week rebuild doesn't add extras.
- **A new dish** is a meal on trial. A dish that's never been made isn't new (onboarding copies dishes the family already makes); it's just due for a turn. New dishes are capped at the setting and go to full-attendance nights first; past the cap only when nothing else fits.
- **Takeout** goes on the busiest night: rushed first, then most people home, then not the shopping day, then earliest. **Leftovers** follow a big-batch meal (tagged leftovers) in the week, else land on the most rushed night.
- **Filters:** in rotation (not archived or retired), not snoozed, not already in the week, outside the repeat window for that night, not disliked by anyone home, quick only on rushed nights, enough lead time for advance prep (thaw first counts as 24 hours; a night has 24 hours per day from today plus about 8 before dinner today), no equipment the household doesn't have (see Kitchen equipment), and nothing that looks to break a food rule on that night (see Food rules). Allergies never filter; they flag.
- **Score:** days since last made for that night (1–90; never made counts as 90), times boosts for a favorite of someone home, ingredients on hand, family likes, and the season, halved for each dish of the same category already in the week; drawn with a seeded generator, so the same inputs and seed give the same week on every device.
- **Season (#54):** from each night's own date, northern hemisphere: summer is June to August, winter is December to February, spring and fall lean nowhere. In summer, dishes tagged grill or with a cold name (salad, gazpacho, wrap, BLT) have double the odds; in winter, dishes tagged slow cooker or with a soup name (soup, stew, chowder, chili) do. Only a name that says cold, chilled, or gazpacho takes a soup out of winter; "Soup and salad" is still a winter dish, and not a cold one. It's one boost however many ways a dish fits. The boost applies after the filters and only moves the odds, so dislikes, the repeat window, locks, and requests are untouched, and allergies still flag and never filter. A library with nothing in season draws exactly as it would in spring.
- **Variety (#54):** a category is a kind of dinner read from the dish's name, roughly the starter pack's: pasta, Tex-Mex, sandwiches, soup, pizza, grilling, chicken, beef, pork, seafood, breakfast for dinner. A dish tagged grill always counts as grilling, whatever its name. A dish can be in several and counts as one repeat of its most repeated category. Each repeat in the week, kept nights included, halves a dish's odds; never to zero, so a family that mostly makes pasta still gets a full week. Only this week counts, not the weeks before. Names are read in English; a name that can't be read gets no lean either way. Shuffle and swap suggestions draw the same way, except that the dish being replaced isn't a repeat; each swap suggestion does count as a repeat for the next, so the three are real choices.
- **Variety nudge (#54):** when three or more nights in a week share a category and a night ahead can still change (not locked, not an event), planners see one quiet note above the cards, for the most repeated category ("Pasta 3 times this week"; "next week" on next week's tab). The whole week counts, past nights too. It only tells; nothing is blocked or swapped. It never names a protein (chicken, beef, pork, seafood): those lean the draw, but a name can't tell a turkey burger from a beef one, so a sentence could be false. It reads only the names saved with the week, so tags don't count here. Never calories or nutrition.
- **Kitchen equipment (#55):** planners set it in Family → Kitchen: grill, slow cooker, air fryer, Instant Pot, all on until someone turns one off. A household that hasn't said keeps every dish. Each toggle saves right away.
  - **What a dish usually uses:** the Needs grill and Slow cooker tags, or a name that says so ("Air fryer wings," "InstantPot chili," "Crockpot roast," "Slow-cooked pork," "Grilled salmon," "Mixed grill," but not "Grilled cheese," "Grilled ham and cheese," "Grilled PB&J," or "Pan-grilled chicken"). Air fryer and Instant Pot have no tag: a new `meal_tag` value would stop apps already installed from reading the library. Names are read in English, and a name can be wrong either way.
  - **Build my week and Fill:** those dishes are left out, like any filter. Foon never plans one on its own: a night only those dishes could fill says Nothing fits.
  - **Never filtered:** requests, someday requests, traditions, locked nights, and past nights being logged. What the family chose lands and stays.
  - **What the planner sees:** any night holding such a dish, however it got there, carries a "Usually uses a grill" badge (the same for the others). It says usually because plenty can be made another way: chili on the stove, hot dogs in a pan. Everyone sees it, like an allergy flag; it never blocks anything.
  - **Using one anyway:** Swap offers them after everything else that fits, with the same badge, and a note under the suggestions says Search finds the rest. Search, I want..., Plan it, and traditions don't filter. Pick for me on an empty night takes one when nothing else fits, since tapping it is a choice. Shuffle won't trade a dish they can make for one they can't, but moves off one already on the night, to a dish they can make if there is one.
  - **Stored:** `households.settings.missing_equipment` (`["grill"]`) and `start_cooking_nudge`, saved only by Family → Kitchen and left out of every other settings save, so a stale device changing dinner time can't undo a planner's list. It holds what the kitchen lacks rather than what it has, so equipment added to the list later doesn't take dishes away from anyone. A value an app doesn't recognize is ignored there and kept when it saves. Two planners changing the list at once: the last save wins.
- **Food rules (#49):** planners set them in Family → Food rules: for each of meat, pork and shellfish, no rule, Fridays in Lent, Fridays, or every night. A rule belongs to the household and says nothing about why: no religion or diet is recorded about anyone. Fish doesn't count as meat.
  - **What it can recognize:** a dish's name, its ingredients, and its sides, in English, by keyword, never by AI (shellfish uses the allergy keywords). It reads "Beef tacos," "Sunday special" with ground beef in it, and a side with bacon, and it knows "Tuna steak," "Veggie burgers," "Hamburger buns," and "Goat cheese" aren't meat. It can be wrong both ways. A name and ingredients that don't say ("Grandma's special") pass. So Foon says a dish looks like it has meat, and never says one doesn't: nothing claims a dish is meatless.
  - **Not offered:** kosher and halal. They depend on how food is made and prepared, which a name can't tell, so Foon doesn't claim them and Family → Food rules says so. Nor is Orthodox Lent, which runs on another calendar. A no pork rule is only that: it doesn't make a week halal or kosher.
  - **Lent:** worked out from Western Easter (Gregorian) each year, so nothing needs updating. Fridays in Lent run from the Friday after Ash Wednesday through Good Friday. Ash Wednesday itself isn't a Friday, so it isn't covered.
  - **Build my week, Fill, Shuffle, Pick for me, and Swap's suggestions and freezer offers:** dishes that look to break a rule on that night are left out, like any filter, with no last resort: a night nothing else could fill says Nothing fits, never a wrong dish. A rule that only makes things harder leaves the night to whatever still fits: takeout comes first, and a rushed rule night takes it as any rushed night would. Then, if the week has a night a Fridays rule applies to, rushed nights draw, then those nights, before new dishes, leftovers and the rest, so a dish they could have isn't spent on Monday. A week without one draws exactly as it would with no rule. Leftovers are the same dish: a big batch isn't paired with a night it would break the rule on, in a build or a shuffle, and a leftovers night with no dish behind it stays off nights a Fridays rule applies. A kept leftovers night doesn't reach back: with a "Leftover Friday" tradition, Thursday's beef stew stays as planned, and Friday's card warns.
  - **Requests:** still land. A dated request lands on its night, since someone asked for it out loud. A someday request takes the first night it can that the rule doesn't apply to, and if everyone who wants it is only home on rule nights, it lands there. Either way the card carries the badge, and the planner can swap it.
  - **Traditions:** sit out that night, since nobody asked for it this week: the night fills as usual, and its chip says "Burger Friday sat out for a food rule". With nothing else to plan, it says Nothing fits. A quick-pick tradition isn't read as a dish.
  - **What the planner sees:** any night ahead holding such a dish, however it got there, carries a badge ("Looks like it has meat: Fridays in Lent"), leftovers and freezer nights too. Everyone sees it, like an allergy flag; it never blocks anything.
  - **Using one anyway:** Swap lists what a rule held back, with why, under the suggestions, and tapping one plans it. It leaves out what's already in the week and tonight's own dish, and shows 12 at most, saying to search for the rest. Search shows the same badge. Plan it says so against each night before the planner picks it. A pinned night, a past night being logged, and "We had something else" are left alone.
  - **Stored:** `households.settings.food_rules` (`[{"avoid": "meat", "when": "lent_fridays"}]`), written only through `set_food_rule`, which changes one food's rule in the list as it is on the server, under a lock, so a stale device can't undo another planner's. The server keeps it from any other write, a settings save or a planner's direct one, whatever they send, as it does the away dates. A rule an app doesn't recognize is ignored there and kept. It's read on the device, so an older app's build doesn't know about it.
- **Shuffle** re-rolls one unkept meal night from the saved week, keeping its kind: a big-batch night stays a big batch, a trial slot stays trial first. Quick-pick nights are changed with Swap, not shuffle.
- **Reasons:** a request, a favorite of someone home, something new, quick for a rushed night, uses what's on hand, the family likes it, "Haven't had it since yesterday / in N days / in a week / in N weeks", or "Due for a turn".

**AI layer (capable devices).** Reads the same inputs plus patterns scoring can't express ("soup when it gets cold," "Thursdays have been leftovers lately") and explains picks in plain language.

**Family polls during planning.** Optional: "Everyone's home Wednesday. Breakfast for dinner, tacos, or eat out?"

**Tonight poll.** When there's no plan or it falls apart, anyone starts a poll among people home tonight: e.g. takeout, hot dogs, leftovers, or a backup dinner in stock. Closes at a set time; no vote counts as abstaining. The poll isn't built yet (#43). When it is, it offers the freezer stash through the same rule Swap uses (`FreezerStash.offers`, for tonight and whoever's home), so allergy flags, dislikes and food rules come along. Someone who eats separately doesn't get a vote: it reads `members.eats_separately` (`Member.eatsSeparately`), which exists already.

**Pivots.** Swapping a night checks the new meal's ingredients against what's on hand and adds gaps to the quick list. Bumped meals offer to move to another night so ingredients don't go to waste.

**Swap sheet.** Three suggestions with reason chips; a quick-pick row of Leftovers, Takeout, Eat out, and Fend for yourselves (everyone makes their own); then search the library or quick-add a dish. The Leftovers option lists which meals have leftovers and how old they are; no quantities. Takeout and eating out are logged without capturing where.

- v1 (#25): suggestions use Build my week's filters and weights for that night (never a dish already in the week; trial dishes only within the week's budget), with "More ideas" to draw again. Quick picks: Leftovers, Takeout, Eat out, Fend for yourselves, Freezer raid. Searching shows your meals, then Foon's ideas (added to the library when picked), then "Add … as a new dish." The planner's pick locks the night so Rebuild keeps it; "Leave it empty" clears and unlocks it. Any night can be swapped, locked ones included; on a past night (logging what was eaten) suggestions ignore prep time, the repeat window, and kitchen equipment. Typing an archived meal's name offers to restore and plan it rather than adding it again. The leftovers list with ages needs dinner logs (M2).
- **From the freezer (#53):** the sheet lists stash items that fit the night, oldest first, between the suggestions and the quick picks. See Cook once, eat twice.
- **Before it changes a linked night:** the sheet says what else moves: swapping a doubled dish takes its leftovers night back, swapping a leftovers night ends the doubling, and swapping a freezer night puts the dish back in the freezer.

**Fridge cleanout.** Leftovers carry their age. The app can suggest a leftovers night when several are piling up and flag old ones: "Monday's tacos are 4 days old. Use or toss?"

**Day cards.** Each night is a card holding everything: effort chip, tap-to-toggle attendance avatars, meal with reason chip, inline lock, shuffle, and swap, and badges. Cards stack like Apple Wallet with tonight on top. The same card is the This Week view and the planning view; an empty card offers Pick for me or Choose. Kids see cards read-only with vote and suggest-a-swap, and anyone can offer to cook from a card (see Claim a night). No family approval step: the planner approves and the list is built.

- **Cooking start time (#55):** a card with a meal can say "Start cooking at 5:45 PM for 6:30 PM dinner," counted back from that night's dinner time (the household's if the night has none). Everyone sees it; it's a line on the card, not a notification. It doesn't show on past nights, on a night nobody's home, for a dish that would have to start the day before, or tonight once the start has passed on the household's clock: nobody can follow an instruction for this morning. Family → Kitchen turns it off for the household. A dish from the freezer has no cooking time, prep step, or equipment note on its card; it's already cooked.
- **Cook once, eat twice (#53):** Double it and the freezer stash.
  - **Double it.** On a night's detail, a planner doubles a dish planned from tonight on and chooses a later night this week for the leftovers. Offered: nights with someone home that aren't away, an event, locked (unless already leftovers), from the freezer, or part of another doubled pair. Picking a planned night says what it replaces. A dish on the week's last night can't be doubled, since leftovers stay in the same week. Dishes from the freezer aren't doubled. Both nights are saved locked, so Build, Fill, and Shuffle keep them.
  - **What the cards say.** Everyone sees "Doubled: leftovers Tuesday" on the dish and "From Monday's Chili" on the leftovers night. Allergy flags for that dish show on the leftovers night, for whoever's home that night. A leftovers night Build placed after a big batch carries that dish's flags too. Any other leftovers night names nothing, because Foon doesn't know what's in it.
  - **The list.** The weekly list doubles that night's amounts, sides included, and only that night's share of an item used elsewhere. Each part says so in the amount: "3 lb (doubled) + 1 lb". An amount that isn't one simple number stays as written and says to scale it by hand ("1 to 2 lb (get double)", "2 lb 8 oz (get double)", or just "get double" with no amount); a package size in brackets is fine ("2 (15 oz) can (doubled)"). Allergy notes count everyone home for the dish or for its leftovers night, since the extra batch feeds both. The list is rebuilt from the plan each time, so Update the list can't scale twice, and undoing it goes back to the recipe's amounts.
  - **An approved week.** Its list waits for Update the list, like any change to a night. The plan remembers the list is behind (`plans.list_stale`) whenever a doubled or freezer link changes, by any path, so every phone sees "Update the list" on This Week until someone does. That's only for dinners still to come: a past night isn't on the list, and tonight's dinner leaves the list's lines once it's logged. That write follows the existing rules: a line someone added by hand or another approved week wrote keeps its own amount with no note on it, and something already bought isn't listed again, so an extra has to be added by hand. Anything marked in stock stays off the list. The Double it dialog says all of this.
  - **Undo and changes.** Undo Double it, from either night, puts back what the leftovers night held and the dish's lock. A dish that's since left rotation, or a night that's now away, stays empty instead, and a night someone has unlocked stays unlocked. A different dish on the doubled night, from Swap, Plan it, Build, away dates, or an older app, does the same. So does the same dish from the freezer, since nothing's being cooked twice any more. A different pick on the leftovers night keeps that pick and ends the doubling; the dish stays locked. A past night, or tonight once its dinner is logged, keeps what was eaten and only loses the link. The server does all of this in triggers. Shuffle isn't offered on a doubled or freezer night, and Swap and Plan it say what else will move. An idea sent back to open because Double it replaced its night stays open after an undo.
  - **We had something else.** It writes only the dinner log, so a trigger on the log does the same on the server. The rule is plain: anyone in the family who can correct a dinner releases its leftovers night and freezer item, since those leftovers don't exist. A doubled dish that wasn't eaten takes its leftovers night back, from today on. A freezer dinner that wasn't eaten goes back in the freezer. Correcting back takes the item out again only if the night still holds that dish and nothing else has the item, and a change to the plan's dish ends that; the leftovers night isn't re-planned, since someone may have planned it by then. The plan keeps showing what was planned, as it does for any corrected night.
  - **Stale phones.** Double it says what the phone saw on both nights, and is refused with its own message if either has changed. Update the list reads the week again first.
  - **Freezer stash.** Lists → Freezer stash holds dinners cooked ahead, each a library dish with the date it was made, oldest first, showing that dish's allergy flags for the family, or saying they couldn't be checked if the library didn't load. Portions aren't tracked: one row is one dinner. Anyone in the family adds to it, marks an item used up, tosses it, or puts it back (it's kept, never deleted). The date can't be after today on the household's calendar.
  - **Offered in Swap.** Planners see items still in the freezer, made by that night, of a dish in rotation and not already in the week. Allergies are flagged, never filtered, for whoever's home that night. Someone home who said Not for me, or a snooze, skips it; on a past night (logging what was eaten) they don't. A retired or archived dish isn't offered, and the list says why, but it stays there to use up or toss. The repeat window, prep time, rushed nights, and missing equipment don't apply. Build my week doesn't plan from the stash; a person chooses it.
  - **A planned item.** Choosing one locks the night with "From the freezer, made Oct 3", and only its sides go on the list. It leaves the freezer at once, so two phones can't both have it: the second is told it's gone. Changing that night, by any path, puts it back. It shows as Planned until its night has passed on the household's day, then with what's gone, saying which night it was on.
  - **Tonight poll.** `FreezerStash.offers` is the one rule for what's offered; the poll (#43) reads it when it's built.
  - **Where the time comes from:** the dish's own Time to cook, set in the meal editor (`meals.cook_minutes`; optional, a picker, copied by Copy and tweak). Starter dishes that aren't quick or slow cooker come with one (docs/starter-pack.md → Cook times). Without one, Foon estimates only where a guess is fair, and says "around": 30 minutes for Quick, 8 hours for slow cooker (by tag or name). Everything else gets no nudge until someone sets a time, because a flat guess would be confidently wrong where it matters.
  - **With prep steps:** while the nudge shows, it replaces a slow cooker prep step, identified by what the step says, and a dish's own time wins over that step's lead. Other steps (thawing, marinating) still show. When tonight's start has passed, the step comes back.
- v1 This Week (#23): tonight's card on top, then the rest of the week; past nights fold into "Earlier this week." With no week yet, planners get Build my week (or start with empty nights) and members get "Add your requests." A started week that's still empty offers Build my week; a partly planned one shows how many nights are open with Fill remaining nights, which drafts only empty nights. Rebuild unlocked nights redraws everything not locked; a draft that finds nothing for a night never clears what it had, and the save refuses a night another planner has locked since. Each card has lock and shuffle (Pick for me on an empty night; quick-pick nights change through Swap). Tapping a card opens the night: meal and sides, dinner time, effort, who's home, and lock. Reason chips are saved with the night so everyone sees them. Allergy badges name only who's home that night, and the first prep step shows as a badge. The cart button shows open list items and opens Lists.

**Event nights.** Holidays and dinner parties are marked on the plan and skipped by voting and ratings. Leftovers from them are still logged.

**Change history and undo (#57).** So two planners don't confuse each other. Everyone in the family can read it: a night's detail shows its recent changes, and Family → Plan activity shows the household's, one line each ("Dad swapped Tuesday to Tacos"). Only planners can undo, on the server and in the app.
- **What's logged:** a change to what a night holds, from any writer: Swap, Plan it, Build, Fill, Shuffle, Double it and its undo, the freezer, away dates, or an older app's direct write. A trigger on `plan_nights` does it, so nothing has to remember to. A whole Build or Fill is one line ("Ann planned 5 nights") and shows night by night in each night's detail. Effort, who's home, the lock, and the reason chip aren't logged. Nor are nights being created, or the plan's list.
- **Who it names:** whoever's signed in when the write is made, including inside server functions. What the system moved on its own says Foon: "Foon cleared Tuesday for away dates," and "Foon put Thursday back to Tacos when Monday's dinner changed" for a leftovers night going back, whoever swapped Monday or corrected its dinner. Someone removed reads "Former member." An entry an older copy of the app doesn't recognize isn't shown.
- **What Undo covers:** the last change on a night, if it was a plain change of pick, from the night's detail. It puts back what the night held (dish or quick pick, and lock) by the same write Swap makes, so everything that follows a night still follows it. The reason chip doesn't come back, since the log keeps no reason: one can name a person ("Wren's request"), and it would outlast them there. A request that was planned there goes back to open as after a swap. In the other direction, undoing a swap puts a request that swap sent back on the night again, if the dish is its dish. A planner's own "not this week" for that dish reads the same on the server, so it lands too. The undo is logged too.
- **What it doesn't:** it's refused, with "Can't undo that one. Swap it instead," for:
  - a night gone by in the household's day, or a logged dinner;
  - either night of a doubled pair, a freezer night, or a change that ended a link, since putting back the pick wouldn't put back the link. Undo Double it and Swap are the ways back there;
  - a dish that's since left rotation;
  - an undo, Double it, the freezer, away dates, or anything Foon moved itself. Undoing isn't a chain: only one step back, and Swap does the rest.
  An away night is refused with the words that say the family's away, even tonight holding a dinner, where a Swap still goes through. Earlier changes on a night can't be undone. The activity view is read-only: open the night to undo.
- **On the phone:** Undo only shows when it should work, and it's disabled while one's on its way, so a second tap can't come back refused after the first worked.
- **A stale phone:** the server holds the night, then checks that this entry is still the night's last and that the night holds what it says, lock included. If not, nothing changes: "That night has changed since. Here's the latest; swap it if you still want to."
- **Older apps:** their writes are logged, and nothing they do is refused because of this. They don't show the log or offer Undo. A failure writing the log never stops a plan write; that entry is just missing.
- **Stored:** `plan_changes`, written only by the trigger and read by the family. Eight weeks are kept, and the daily retention job deletes the rest. A device reads the latest 300.

## After-dinner loop

The plan is the log by default; one notification per person confirms it, rates it, and captures leftovers.

**The prompt.** About an hour after that night's dinner time, everyone expected home gets: "Mac and cheese tonight?" with Favorite, Good, Not for me, Tired of it, "We had something else," and "Wasn't home." Any reaction confirms the meal and records that person's rating in one tap. If anyone picks "something else," they correct the log and everyone's prompt updates. No cook assignment needed.

**First responder extras.** Leftovers: yes or no, pre-filled with the app's prediction when someone was out. Quantity isn't tracked. Who cooked: tap a family face (optional). An optional "it was off tonight" checkbox separates a bad night from a bad recipe. The optional one-line comment is for everyone who rates, not only the first; see Comment card under Prompt design.

**No responses.** Auto-confirm overnight, marked unverified so the planner can spot gaps.

**Prompt design.** A rich notification card (long-press, no app open needed): one tap on a reaction saves, no submit button. First responder gets pre-filled Leftovers and Who cooked rows. "We had something else" opens a mini swap sheet, then asks whether to move the planned dish to another night. A missed prompt shows as a slim card on This Week until the next evening. "It was off tonight" lives one tap deeper. **Comment card (#149):** right after someone rates from their card, a second card asks "Anything to say about the chili?", with one short line (140 characters, line breaks become spaces), Save and Not now. It asks once, after that rating: Not now or a save ends it, and so does the app restarting. It stays on This Week until then, and if the rating's 24 hours run out first, the server refuses the save and says so. Rating isn't held up by it. What's typed is lost on switching to next week and back. Pass the phone doesn't ask, to keep it quick, so a profile with no account of its own doesn't write comments yet. The card says the comment is about the food, not the cook, and only the family sees it, which goes for kids' comments too: nothing outside the household reads them, and there's no sharing. Someone who eats separately isn't offered it, and the server refuses it. It has no way to change a comment after saving. "It was off tonight" isn't built. Reactions can be changed for 24 hours, then lock into history.

| Reaction | Effect |
| --- | --- |
| Favorite | Pinned to that person; resurfaces regularly, especially on their home nights |
| Good | Default: we ate it, it was fine |
| Tired of it | Temporary snooze; out of suggestions for a few weeks |
| Not for me | Lasting dislike from that person |

**Dislike rules**

- 0 dislikes: full rotation.
- 1 dislike: suggested only on nights that person is away.
- 2 or more dislikes: retired (archived, still findable).
- Dislikes never expire on their own: a dislike stands until that person rates the dish again (their latest reaction is their verdict). Removed members' verdicts don't count. Ratings are family-only; guests don't rate. New ratings are for the last week's dinners. A retired dish stays retired unless a planner brings it back (Back in rotation, after a confirmation that the family voted it out); its dislikes still keep it off nights those people are home, and a new Not for me can retire it again. Quick picks aren't rated (decided 2026-10-28).
- **Eats separately (#49):** a parent can mark a member, usually a baby or toddler, as eating separately. They aren't asked to rate (no card, not in Pass the phone), and the server refuses a rating for them. Ratings they already have stop counting, like a removed member's: no dislike, favorite, or like, and they don't count toward retiring a dish. A dish already retired stays retired. Turning it off brings their ratings back, but doesn't re-run the dislike rule: a dish their rating would now retire stays in rotation until the next Not for me on it. They still count as home: on attendance, for allergy flags and serving notes, so the people cooking still see what's true. It's about ratings and votes, not asking: they can still be who asks for a dish in I want... A person who eats separately can be planned around but isn't asked about the food.

**Transparency.** Reactions are visible to the whole family. Always rate the dish, never the cook; the prompt asks about the food ("How was the chicken thing?").

**Cook credit.** Every logged dinner records who made it, with no rating attached. A monthly "cooked this month" tally and a one-tap "Thanks, chef" make contributions visible and encourage more cooks. Beginner-friendly tags give kids a shortlist they can make on their own.
- v1 (#46, part 1):
  - **Thanks card:** once someone is down as the cook and that's settled (the dinner's confirmed and the first responder has saved the follow-up), This Week shows "Ann cooked: Chili" with a one-tap **Thanks, chef** for everyone else, while that night's card is open. The cook sees how many thanks they got.
  - **Rules:** thanks come from your own profile, once per dinner, never to yourself, only for a cooked dish (not a quick pick), for a dinner from the last week, and are never taken back. Once someone has said thanks, the cook and the dish on that log stay as they were.
  - **Family tab:** "Cooked this month" lists each cook's dishes and thank-yous, in family order (credit, not a leaderboard), from the month's logs in the household's time zone. Quick picks don't count.
  - **Retention:** a withdrawn kid's own thanks are erased with their other contributions.

**Claim a night (#50).** Anyone can say "I'll cook Thursday" on a night's card, a planner or not, a kid or not. A claim is a promise and a log is what happened: credit only ever comes from the log.
- **Who:** you, or (in a night's detail, passing the phone) a profile nobody has claimed. A planner can't volunteer someone with their own account. Someone who eats separately isn't offered, nor is anyone marked out that night, and the server refuses both; "Who cooked?" leaves out someone who eats separately too. To cook a night you're marked out for, ask a planner to change who's home.
- **Which nights:** tonight or later, in the household's day, with nothing logged yet and something to cook: a dish or an empty night, not a quick pick. Past nights, away nights and quick-pick nights have no button.
- **Two people:** a night has one cook. The second person is told someone got there first, and the card then shows who. Tapping again changes nothing.
- **Shown:** the card shows the cook's avatar and "Ben is cooking" (or "You're cooking"). Once a dinner's logged, the card goes by the log ("Ben cooked"), and says nothing if nobody's down. A night gone by with no log says nothing.
- **Taking it back:** whoever offered, anyone for a profile nobody has claimed, or a planner, from the night's detail, until the dinner's logged. The row stays, marked released; it's never deleted. By the claim, not the night, so a phone that's behind can't end someone's newer claim.
- **When the night changes:** nothing keeps a claim in step with its night. It's read along with the night as it is now.
  - Swap, Plan it, Build my week, Fill, Shuffle, the freezer, or clearing the night: the promise stands, whatever's on the night.
  - A quick pick, including the night that becomes leftovers from Double it: on hold. The card doesn't say anyone's cooking, the night's detail says why, and it counts again if the night goes back to a dish.
  - The person marked out: on hold the same way, and someone else can take the night, which ends the old claim.
  - Away dates covering the night: it ends, and shortening the dates doesn't bring it back. Tonight keeps a dinner it already has inside new away dates, so its claim stands too.
  - Removed, deleted, or now eats separately: it doesn't count.
- **Feeding credit:** when a new log is made for a dish (the first tap, or the overnight job), its cook starts as whoever's claim stands. Confirming a saved log doesn't look at the claim again. No credit for a quick pick, or anyone marked out, removed, or eating separately. "We had something else" keeps the cook for the first responder to fix, and a quick pick doesn't count as cooking. An overnight log nobody confirmed still gives the credit from the claim: nobody said otherwise.
- **A default is a guess until it's settled.** "Who cooked?" starts on them, and the first responder can change or clear it. Their Save sends the cook only if they changed it, so a card opened earlier can't put back someone who has since been taken off. Thanks, chef waits until the log is confirmed and that follow-up is saved, on the server too, because a thanks locks the cook and mustn't lock a guess.
- **"That wasn't me":** whoever's down as the cook sees it on their own card from the start, even on an unconfirmed overnight log, and in the night's detail after the card closes. In the detail, anyone can say it for a profile nobody has claimed, and a planner for anyone. It sends only the cook, and a blank cook stays blank. "Wasn't home" also takes you off as the cook. Once someone has thanked the cook, the cook and dish stay: "That wasn't me" is no longer offered, a correction is refused with "Someone already thanked the cook", and "Wasn't home" still saves that you were out and says you're still down as the cook.
- **Timing:** a confirm doesn't lock the night, because that could deadlock with We had something else. So a claim made in the same instant can leave the cook blank, and a claim being taken back in the same instant can still name that person. Both are defaults, and can be corrected like any other.
- **Planners hear about it:** in the app for now, a note at the top of This Week ("Ben will cook Thursday"), dismissed per device, for someone else's claim on a night still ahead that stands as it is. Not one you entered yourself. Taking a claim back has no note; the card just changes. **M2 car 6** adds the push, reading the same thing: rows in `night_claims` with no `released_at`, sent to the household's planners except whoever entered it, after asking `household_away_on` like every other send.
- **Retention:** a withdrawn kid's offers they made themselves are erased, and ones a parent entered stay. Deleting anyone's account, adult or kid, or removing a kid under retention ends their open claims. An adult's past ones stay as anonymous history, and a kid's stay on their profile. Export includes them.
- **Older apps** don't read claims. They log dinners through the same `confirm_dinner`, so the default still lands. Their follow-up card only shows when no cook is set, and only the first responder gets that card. So when the first responder is on an older app on a claimed night, nobody's asked about leftovers, and the dinner can't be thanked until something saves them. The cook can still say "That wasn't me" from a current app. Their Thanks card can appear early, and the server refuses it.

**Dinner jobs (#50).** Optional helper jobs: set the table, clear the table, do the dishes. Off until a planner turns one on in Family → Dinner jobs, which also says who takes turns. Everyone's in by default, including someone added later; a planner can leave someone out. Someone who eats separately is never in it.
- **Who does what:** worked out on the device from the week, so every phone shows the same thing and nothing is stored or assigned. Through the week in order, each job goes to whoever's home that night who has done least this week, then that job least. Who starts moves on each week. People home the same nights stay within one of each other. Whoever's claim stands has the night off, and nobody gets two jobs in a night. With too few people, the job done least this week goes first, so a different job doesn't show each night, not always the same one.
- **Which nights:** tonight or later, with something on the table: a dish, leftovers, takeout, or a freezer raid. Not eating out, fending for yourselves, an empty night, or an away night; those don't use up a turn.
- **What can shift:** a card says whose turn it is as things stand. Later nights that week can change when someone offers to cook or takes it back, when who's home changes on any night that week (including "Wasn't home" on a night gone by), when a night's plan changes between having jobs and not, or when a planner changes the jobs or who takes turns. Answering "Who cooked?" doesn't change anything, nor does a promised night going by, since the turns go by claims and never logs.
- **No score:** no check-off, no reminders, no tally, and nothing about who did or didn't. Can't do it tonight? Trade. It's only ever words on the card and in the night's detail.
- **Settings:** `households.settings.dinner_jobs`, written only through `set_dinner_job` and `set_dinner_job_person`, one change at a time under a lock, so two planners can't undo each other and a whole-settings save from a stale phone or older app can't touch it.

**v1 effects (#42, part 3).** A person's current verdict on a dish is their latest reaction to it:
- **Favorite:** pinned to them; Build my week boosts it on their home nights.
- **Tired of it:** out of suggestions for three weeks after that dinner.
- **Not for me:** lasting. With one person it's suggested only on nights that person is away. When two people's current verdict is Not for me, the server retires the dish (still findable under Archived).
- **Likes:** every Favorite or Good ever adds a small boost.
- **Freshness:** This Week re-reads reactions each time it loads, so last night's answers count in the next build.

**Pass the phone.** At the table, everyone rates in about 20 seconds on one device; a natural ritual and a fallback for kids who ignore notifications.

**v1 data (#42, part 1).** One log per night (`meal_logs`) and one reaction per person per log (`reactions`), visible to the whole family; neither is ever deleted.
- One tap (`react_to_dinner`) confirms the planned dinner and saves that person's reaction in one transaction.
- Only a dinner that has happened and had something planned is logged; an empty night is logged by swapping in what was eaten first. Only dishes are rated, not quick picks.
- Anyone in the family can then correct what was eaten ("We had something else"), leftovers, and who cooked. A confirmed dinner stays confirmed, and a log saved overnight follows later changes to the plan until someone confirms it.
- People react for themselves. On a shared phone, anyone in the family can react for a profile nobody has claimed: kids without phones, or pass the phone.
- The server records who confirmed and whose phone last wrote each reaction, as profiles, never accounts.
- A reaction can be changed for 24 hours, then it locks.
- An hourly job saves the last week's unanswered, planned nights of approved weeks as unverified once the household's day is over.
- The household's time zone (set when it's created) decides when that is; without one, the server uses America/New_York.
- **Hiding a comment (#49, #149):** a planner can hide a comment or show it again, from meal detail. Nothing's deleted: the rating stands, and the text is kept. The family stops seeing it, its author included; planners still see it, marked, so they can bring it back. It's enforced on the server: row-level security can't hide one column of one row, so `set_comment_hidden` moves the text out of `reactions.comment` into `hidden_comments`, which only planners can read and nobody writes directly. `meal_comments` is what the app reads, and it brings the text back for planners only. Writing a comment that's hidden through the API keeps it hidden: new words go to `hidden_comments`, and clearing it clears the words but not the hiding, so clearing and writing again doesn't publish it. A rating change leaves it alone. The export is a planner's, so it has the text, in its own `hidden_comments` section. Retention treats it like any other comment: clearing `reactions.comment` clears the hidden words, and deleting a reaction takes the row along.
- Deleting an adult's account keeps their reactions as anonymous history but clears their comments.
- Deleting a kid's account clears their comments too, hidden ones included (decided 2026-11-01). Their ratings stay on the profile their parents entered. Showing the words under another name wouldn't protect them: in a family, the words say who wrote them.
- Retention covers reactions the same way: a removed kid's comments are cleared with their name. When a kid's own-device consent is withdrawn, after 30 days the ratings they last wrote themselves are erased and their comments are cleared; ratings a parent entered for them by passing the phone stay.

**v1 card (#42, part 2).** Until the rich notification card (#122), the prompt is a card at the top of This Week; on Balanced and Engaged a local notification opens it (see On-device reminders). It shows for each dish you were expected home for, from an hour after that night's dinner time until the same time the next evening (the missed card), and goes away once you rate it. Times are the household's (its time zone), and the card appears on its own if the app is left open. Someone with no attendance row for that night (added to the family after the week was made) gets no card.
- "Chili last night?" (or "tonight?") has four reaction buttons about the food.
- **We had something else** picks a quick pick or one of your meals as what was actually eaten. It's offered only until someone rates the dinner; after that the server keeps the dish, so a rating never moves to a different one.
- **Wasn't home** (after a confirmation) marks you away for that night, within the last week. Anyone can say it for themselves or, in Pass the phone, for a profile nobody has claimed.
- **Pass the phone** lists everyone home: you and profiles without their own account are rated right there, and anyone with their own account shows read-only with their answer.
- The first person to answer then gets "Anything left over?" (pre-filled Leftovers when someone expected was out, else All gone) and, for a dish, "Who cooked?" (tap a face, optional), and Save. Each answer saves only its own fields, so two phones answering different questions don't overwrite each other.
- Last night's card shows even when last night was in the previous week.

## Shopping and pantry

The plan produces one weekly list; pivots and running-out moments produce the quick list. Store-agnostic: no store setup or store logic.

**Weekly list.** Generated from the approved plan's ingredients, minus what's on hand, merged with low or out staples. A doubled night counts twice, and a night from the freezer adds only its sides (see Cook once, eat twice). Designed so one big trip covers the week.

- v1 (#26): Approve on This Week (planners) shows the item count and builds the list from the nights still ahead: each meal's ingredients and sides, merged by household item with their amounts joined ("1 cup + 2 cups"), minus items marked in stock (low still counts), plus keep-on-hand staples that are low or out. An item someone home that night can't have gets a note ("Get dairy-free (Nora)"). Approving again after a swap updates that week's list: lines it added that are no longer needed go, the rest refresh, lines added by hand stay, and anything already bought for that week isn't listed again. Approving next week never touches this week's lines. When allergy notes don't fit, a compact note still names every allergen ("Check: dairy, kiwi (Nora +2)"). The cart badge updates right away.

**Quick list.** Fill-in trips during the week. Fed by pivots ("mac and cheese needs milk"), staple taps, and shared text. Items carry urgency ("for tonight's dinner" vs "whenever"). Duplicates merge: milk from a pivot and milk from a tap show once.

- v1 Lists and store mode (#27), all from the offline cache: the Lists tab has Add an item (quick list, typed naturally with autocomplete; "for tonight" makes it urgent; a brand-new item needs a connection), On the list (tonight's quick items, then the week, then the rest; amounts, brand notes, and allergy notes shown), and Staples running low (one tap adds). Swipe for Got it or Remove; tap for the item's note and aisle. Shop opens store mode: aisles in walking order with non-food last, big rows, checked items sink into "In the cart," and the screen stays awake. "Couldn't find it" moves an item to the quick list (with a note) and under "For next time." A trip stays open across closing store mode until Finish trip, which restocks the staples bought and says what's left; checking off a staple anywhere restocks it right away. Two shoppers see each other's check-offs over Realtime.

**Keep-on-hand list.** Everyday staples (cereal, milk, bagels, apples, pickles, snacks) and backup dinners (box mac and cheese, frozen pizza, pasta and jarred sauce). Each item is in, low, or out; no counting. Anyone taps low or out. Backup dinners in stock feed the tonight poll and tonight rescue.

**Pantry state without counting.** Receipt scanned: items count as on hand and staples flip to in. Meal confirmed: its ingredients count as used. Backup dinner cooked: marked used and lands on the list to restock.

**Offline.** The lists and the week's plan are cached on device; check-offs sync when signal returns.

**Receipts (v1.5).** Photo of the receipt, or a forwarded digital receipt email. Direct retailer APIs are parked: chains rarely expose purchase history to outside apps. Receipts mark items bought, clear them from the list, and teach the app the family's staples ("Add apples to keep-on-hand?"). Hard part: normalizing receipt abbreviations to canonical items, improved by user corrections.

**Shopping insights (later; needs 4 to 6 weeks of receipts, including quick trips)**

- Quantity tuning: "You buy strawberries Sunday and again Wednesday. Buy two on Sunday?"
- Run-out prediction: "Apples usually last 7 days; it's been 10."
- Drift detection: "No apples in 4 weeks. Still a staple?"

## Notifications

Few, actionable, and answerable from the lock screen. Every notification asks for one tap or saves someone from remembering something.

**Away dates pause them (#52).** Nothing is sent about a night inside the household's away dates (Attendance → Away dates), and Time to plan and Requests open skip a week that's all away. On-device reminders read `HouseholdSettings.isAway(on:)`, and server pushes (not built yet) will ask `public.household_away_on(household, date)`.

| Notification | Who | When | If ignored |
| --- | --- | --- | --- |
| Requests open | Everyone | Evening before planning day | Pause for that member after 3 ignored weeks |
| Time to plan | Planners | Planning day and time | One follow-up, then an in-app banner |
| Plan's set | Everyone | On approval | Nothing |
| Prep reminder (thaw, marinate, start slow cooker) | Planners, or whoever's home | Relative to dinner time | One follow-up, then drop |
| Day-of check-in, with dinner preview on its card | Everyone expected home | Planner-set time, default 3:30pm | No answer means home |
| No plan tonight | Adults | Afternoon | Nothing |
| Tonight poll | Whoever's home tonight | When started; closes at set time | No vote means abstain |
| After-dinner confirm and rate | Whoever was expected | About an hour after dinner time | Downshift to weekly roundup after 3 ignored nights |
| Allergy flag | Planners | Shown in-plan until acknowledged | Never a dismissible push |
| Urgent list item | Adults | When added ("milk for tonight") | Nothing; ordinary staple taps notify no one |
| New requests | Planners | Batched digest | Nothing |
| Weekly recap | Everyone (optional) | After the week | Nothing |

**Action buttons.** Prep reminders offer Done, Remind me in an hour, or Swap tomorrow's dinner. The day-of check-in is Home or Not home; planners hear only about changes, and the app reacts (leftovers expected, offer a swap if the absent person was the reason for the pick). See Day-of check-in below.

**Keeping kids engaged without nagging**

- **Budget:** a household cap on pushes per member per week (default around 4 to 6 for kids).
- **Downshift, don't stop:** nightly ratings become a weekly roundup, then a gentle "want these back?" a week or two later.
- **Show influence:** "Your steak request made Friday," "Your vote broke the tie."
- **Pass the phone** at the table as the fallback.
- **Planner engagement view:** a quiet note like "Owen hasn't sent requests in 3 weeks" so a parent can nudge in person.
- No streak shaming, ever.

**Day-of check-in (#41).** "Home tonight?", from each person's own device, on Balanced and Engaged.
- **When:** Family → Rhythm's "Ask who's home at", 3:30pm by default. A planner sets it, like the rest of Rhythm, so a teen who's a planner can too (the open question under Notification presets).
- **Who:** anyone expected home that night, in an approved week, on a night with a dish or a quick pick other than Fend for yourselves. Not once dinner's logged, once they've answered on any phone, on an away night, or if they have no attendance row. No follow-up, since no answer means home.
- **The words are fixed like every reminder's:** "Home tonight?" and "Tap to see what's for dinner." The dinner preview is on the card a tap opens, because a lock screen never names a dish (decided 2026-10-31).
- **Answering:** Home and Not home on the notification, without opening the app, or the card on This Week, which shows from the check-in time until dinner. After a no, the card says so and offers "I'll be home" until dinner. A lock-screen answer with no signal is kept on the device and sent the next time the app runs, unless it's stopped mattering; until then this device plans as if it landed. An answer on the card replaces one still waiting. If the server refuses a lock-screen Home because a planner has them out, nothing tells them: the card won't be there, and This Week shows them out. On Light there's no card either.
- **Who can say:** yourself, for tonight only. The server's `answer_check_in` also lets someone answer for a profile nobody has claimed, like Wasn't home, though no screen offers that yet. "Home" can't overrule a planner who marked them out; only their own no can be taken back. A planner's later write to that person's attendance wipes the answer, even one that leaves them out, so it isn't news any more and it's the planner's to change. Someone a planner has out who says Not home changes nothing.
- **What a no does:** they're marked out, as if a planner had. That feeds Wasn't-home's rules (off the log as the cook, unless thanked), puts a claim on hold, drops their after-dinner prompt, and pre-fills the leftovers question.
- **Planners hear only a no:** in the app for now, a note at the top of This Week ("Ben won't be home tonight."), dismissed per device, not for their own. It reaches them when This Week next loads (opening the app, coming back to it, or pulling down), so a planner may not see a late no before cooking. A push needs server push (#40), which reads the same rows: `expected = false` with `checked_in_at` set. "Expect leftovers." shows when a dish is being cooked and someone's still home. A Swap dinner button shows when the night's reason chip names them ("Ben's favorite", "Ben's request"). The chip is saved as words, so a planner on another language doesn't get the offer; Swap is still on the card.

**Delivery (decided 2026-10-28, M2).** Two paths:
- **On the device:** reminders tied to a person's own plan and clock are local notifications, scheduled from the offline cache. These are prep reminders, the day-of check-in, the after-dinner prompt, Time to plan, and cook-mode timers. They work offline, and each member's budget and quiet hours are applied on their own device.
- **Server push:** anything another person triggers comes through APNs from Edge Functions. These are Plan's set, urgent list items, new requests, claims, the tonight poll, heading to the store, and "your request made the plan."
- **Log:** `notification_log` records what was sent and what was answered, from both paths, for ignore handling.

**Notification presets** (decided 2026-10-30). Onboarding's "Your rhythm" step picks one for the household; the screen describes the selected one. Each is a starting point that later settings tune per person.

| Preset | Sends |
| --- | --- |
| Light | Only what you'd hate to miss: Time to plan, Plan's set, urgent list items, and prep reminders. No dinner rating prompts or polls; kids get almost nothing. |
| Balanced (default) | Light, plus the day-of "home tonight?" check-in and the after-dinner rate-the-dish prompt (downshifting to a weekly roundup when ignored). Kids are capped at about 4 to 6 a week. |
| Engaged | Everything: new-idea digests, the tonight poll, heading to the store, the weekly recap, "your idea made Friday", and one follow-up on reminders. |

Today a preset covers what's built on the device: Time to plan and prep reminders on all three, the day-of check-in and the after-dinner prompt from Balanced up, and one follow-up on Time to plan and prep reminders on Engaged. The rest needs server push or its own ticket, and onboarding and Family → Rhythm say it's on the way. A planner changes the household's preset there. That includes a teen who's a planner, which the Settings line below ("adults own household settings") doesn't allow for; open question for car 6.

**On-device reminders (#40 part 1).** `NotificationPlanner` is a pure function from the person, this week and next from the offline cache, the household's settings, and what's already gone out, to what should be scheduled. It runs when Foon comes to the foreground and when the plan, the family, the rhythm, or a rating changes on this device.
- **Time to plan:** planners, on the planning day and time, about the first week starting on or after that day. Not for a week that's approved, or one that's all away.
- **Prep reminder:** each prep step with a lead time, counted back from that night's dinner; whole days keep their clock time across daylight saving. It goes to the planners home that night who have their own account, or if there are none, the adults home. Not for an unapproved week, a past night, a night nobody's home, an away night, a quick pick, or a freezer or leftovers night, and never once it's too late. Actions: Done, Remind me in an hour (not offered if an hour from then is dinner or later), and Swap dinner, which opens Swap for a planner and the night for anyone else. A step with no lead time gets no reminder.
- **Words (decided 2026-10-31):** every word in a reminder is fixed: "Dinner tonight" (or tomorrow, or a weekday), a line for the kind of step (thaw, marinade, slow cooker, or "Time to start prep."), "How was dinner?", "Tap to rate dinner.". No dish name, no step's own words, and no person's name, on any reminder or follow-up, because a family types those and a check on them can't be complete. The dish shows in the app after a tap. A family opt-in for dish names can come later. The cached reminder plan holds no dish names and no step text, only each step's kind and lead time.
- **After-dinner prompt:** whoever was expected home, at the moment the This Week card opens, for a dish. Not for someone who eats separately, once they've rated it, or if someone logged something else. Tapping opens the card.
- **Day-of check-in (#41):** see above. It shares a place in the budget with the prompt, soonest first, so a kid on Balanced gets both for the first nights of the week and neither for the last ones.
- **Budgets, per person per household week, counting what's gone out:** kids 2 on Light, 5 on Balanced, 6 on Engaged; adults 8, 12, 16. When it runs short, Time to plan comes first, then prep, then the check-in and the prompt, then follow-ups. No allergy or safety notice is a reminder, so a budget can't drop one (the allergy flag is in the plan, and never a push).
- **Quiet hours:** 9pm to 7am for everyone, plus 8am to 3pm on weekdays for kids (it doesn't know about school holidays). A prep reminder moves to 15 minutes before the quiet stretch, or, if that's gone by, to the end of it as long as at least half its lead time is left before dinner; its title says the day from when it goes. Time to plan moves to the end of it, and so does a check-in if that's still before dinner, so a kid is asked at 3pm if it's set for school hours. A prompt or a follow-up doesn't go. A snooze goes when it was asked for.
- **Whose clock:** the household's day and time zone, so one instant whatever zone the phone is in. A travelling phone follows home, quiet hours included, so it can buzz in someone's local night. A household with no time zone saved uses the server's New York fallback, the same clock as the after-dinner card, so the prompt and the card agree. Out west that's early, for both, until a planner's device saves the zone.
- **Stale data:** nothing is planned from a read more than two days old, and nothing goes out more than eight days after the read. A plan changed on another phone reaches this one when Foon next opens here; until then what's pending stays pending. There's no background refresh or push yet to take it back.
- **Asking:** never at first launch. Reminders take two yeses: this person's own opt-in on this device, and the system's permission, which cook-mode timers may already have. Once a week is approved and there's something to remind this person of, This Week shows one card, whether or not timers got permission first. Turn on sets the opt-in, and asks the system only if it hasn't been asked. "Not now" ends the card, on this device. Family has the switch: on, off, or a link to Settings after a no there. Turning it off cancels pending reminders and leaves cook-mode timers alone. Without both yeses, nothing is scheduled or logged and the app works as before. Mac too.
- **Leaving:** sign-out, deleting an account, and a household that's gone cancel everything pending and clear Notification Center (cook-mode timers included), the cached plan, the records, unsent answers, and the opt-in. Every reminder's identifier carries the person, so the next person on the device doesn't inherit one.
- **Stored:** `notification_log` holds one of the spec's types, a channel, a night, and times, with one of opened, done, snoozed, or swap: no text and nothing about allergies. A device writes only its own rows, through `record_notifications`, when it can, at most 200 new ones a day, and a row that won't read is dropped rather than failing the rest; they wait on the device, apart from the shopping list's queue, and are dropped unsent after about two weeks. Planners read the household's, and everyone reads their own. Eight weeks are kept. Deleting an account (a kid's too), removing a kid under retention, and withdrawing a kid's consent delete their rows; it's in the export. A row with no `sent_at` was called off.

**Settings.** Smart defaults; presets in onboarding (Light, Balanced, Engaged); advanced settings for every cap, time, day, and frequency, household-wide or per member. School-hours quiet window for kids' devices by default. Adults own household settings; kids can only turn their own notifications down.

## AI strategy

The app is mostly code; Apple's on-device Foundation Models framework is a helper layered on top. No server AI, no bring-your-own subscription in v1.

**Why on-device.** Free inference, offline, private. Constraints: roughly 3B parameters, a 4K-token context, and only on eligible devices with Apple Intelligence enabled. So AI handles language tasks; scoring and planning stay in code.

**Household AI queue.** AI is a household resource, not a per-device one. Older phones submit jobs (parse this recipe link) to a Supabase queue; capable phones claim them on app open and via background tasks. Results sync to everyone. Partial results appear instantly (title and link, marked processing). If no capable device claims a job in time, the non-AI path runs. Our house: 2 capable devices, 2 not.

| AI feature | Non-AI fallback | Value kept | Lift |
| --- | --- | --- | --- |
| Recipe capture from anything | schema.org parsing; Vision text recognition with tap-to-pick ingredients | \~80% | Low |
| Natural-language and Siri input | App Intents with fixed phrases ("Add milk to the list," "What's for dinner?") | \~60% | Low |
| Tonight rescue (3 ideas from what's here, time, who's home) | Same scoring code over backup dinners, quick meals, leftovers | \~80% | Low |
| Receipt cleanup | Vision text recognition plus fuzzy matching against confirmed items | \~65% | Medium |
| Weekly recap | Templated stats | \~85% | Low |
| Beginner cook mode | One step per screen with timers, beginner tag | \~50% | Low |
| Leftover makeovers | Leftover-friendly tag and a small built-in idea list | \~40% | Medium |
| Plan explanations and pattern picks | Build my week algorithm alone | \~70% | None |
| Prep-step detection from recipe text | Keyword detection ("marinate," "overnight," "slow cooker") | \~70% | Low |

**Onboarding sells outcomes, not "AI."** "Share any recipe and it lands in your ideas" is true on every device; capable devices just do it better.

**Positioning.** Your family's data, including your kids' data, never leaves your devices for AI processing.

**Later.** Bring-your-own AI via an MCP server exposing meals, ratings, and lists to a user's own agent.

## Technical architecture

iOS-only, multiplatform SwiftUI (iPhone, iPad, Mac) on Supabase, with a local cache for offline use.

**Client.** SwiftUI app; SwiftData cache for the plan and lists; Share Sheet extension; widgets ("Tonight: tacos"); App Intents for Siri and Shortcuts; actionable push notifications; Vision for text recognition; Foundation Models for on-device AI.

**Backend.** Supabase Postgres with every table scoped by `household_id` and row-level security from day one; Realtime for live list check-offs; Edge Functions for push notifications (APNs) that someone else triggers, recipe-site parsing, and invite codes; Storage for receipt images if retained.

**Why not CloudKit.** Relational queries (ratings by person, dish, and night against attendance), realtime collaboration, and a possible future web page. Trade-off: owning hosting cost and the privacy story.

**Data model sketch**

| Table | Key fields |
| --- | --- |
| households | name, owner, settings (JSON), founding flag, subscription status |
| members | household, first name, avatar, adult or kid, guardian, role (planner, member), status (active, away, removed), user link (null until claimed), attendance defaults |
| allergies | member, category, custom text (guardians edit; needs allergy consent) |
| consents | household, member (kid, for parental), kind (allergy data, parental), granted by, granted at, revoked at, wording version; append-only |
| meals | household, name, servings, tags, prep steps, recipe steps, source URL, photo, made by, time to cook, status (active, trial, archived, retired) |
| meal\_ingredients | meal, item, quantity (optional) |
| meal\_sides | meal, side meal or item, position |
| items | household, canonical name, category (groceries, household, personal care), keep-on-hand flag, stock state (in, low, out), note or brand preference |
| plans / plan\_nights | week start; per night: date, meal, effort, dinner time, second seating time (model only, see Outliers), locked, event flag, leftovers from (the doubled night) and what that night held before, freezer item |
| freezer\_stash | household, meal, made on, state (in, used, archived) |
| night\_attendance | plan night, member, expected, checked\_in\_at (they answered the check-in; `expected` holds what they said), confirmed, seating (model only, see Outliers) |
| attendance\_templates | household, name, schedules (member id to their attendance defaults) |
| meal\_logs | plan night, meal or quick pick actually eaten, cooked by, leftovers, verified, confirmed by |
| night\_claims | household, plan night, member, entered by, released at (at most one open per night) |
| reactions | meal log, member, reaction, off-tonight flag, comment (empty while hidden) |
| hidden_comments | reaction, household, comment, hidden at (planners read; only the server writes) |
| requests | household, member, meal, name or link, note, target date (optional), status, planned night; me-toos in request\_plus\_ones |
| list\_items | household, item, list (weekly, quick), urgency, source, checked |
| polls / votes | household, night, options, closes at; member, choice |
| receipts / receipt\_lines | household, date, image; raw text, matched item |
| ai\_jobs | household, type, payload, status, claimed by device, result |
| notification\_log | member, type, channel, night, scheduled, sent, responded (drives ignore and budget rules) |

**Payments.** StoreKit 2 with server-side entitlement on the household. Two subscription products: standard and Founding Family.

## Family-life features

Every family is different; these are all in, each optional and off or unobtrusive by default, assigned to the phase where they fit.

| Feature | What it does | Phase |
| --- | --- | --- |
| Standing traditions | Recurring nights (Taco Tuesday, Pizza Friday) auto-fill each week unless swapped. v1: one per weekday, a library meal or quick pick with an optional name for the chip; planners set them from This Week → Traditions. Build my week lands them after dated requests (a request wins its night) and saves them locked; a meal no longer in rotation is skipped, and a tradition sits out a week when it's snoozed or someone home that night said "not for me" (the repeat window, rushed nights, and prep time don't apply, since it's chosen on purpose); quick-pick traditions count toward the takeout and leftovers settings. Swapping a tradition night changes only that week | 1 |
| Side dishes | Optional side pairings per meal (salad, garlic bread) so the list is complete. A side is a library meal (its ingredients join the list) or a simple item (added itself); one level, so sides of sides aren't followed. Shown on day cards ("with salad and garlic bread") and meal detail ("Goes with"); Copy and tweak keeps them. Archived meals can be sides; retired ones can't, and a side retired later drops off. Allergy flags include sides | 1 |
| Non-food items | Household and personal care items (paper towels, toothpaste) live on the same list, sorted after groceries in store mode, and can be keep-on-hand staples | 1 |
| Item notes and brands | "Vanilla yogurt, not plain," "store brand": a standing note per item (80 characters), set by anyone at home and shown with the item on meals, lists, and in store mode | 1 |
| Claim a night | Anyone taps "I'll cook Thursday"; voluntary, visible, feeds cook credit. v1: see Claim a night (#50) | 2 |
| Heading to the store | One tap tells the family to add items in the next 10 minutes | 2 |
| Vacation or pause mode | Skip planning, notifications, and lists for away days. v1: see Away dates (#52) | 2 |
| Season templates | Save and switch attendance patterns (baseball season, school year, summer). v1: see Saved schedules (#52) | 2 |
| Cook once, eat twice | "Double it" plans the leftovers night; freezer-stash list of meals cooked ahead. v1: see Cook once, eat twice (#53) | 2 |
| Seasonal weighting | Grill and cold meals rise in summer, soups and slow cooker in winter (see Build my week) | 2 |
| Variety nudges | "Pasta 3 times this week", and the draw leans away from a category as it repeats; no calorie or nutrition tracking, by design | 2 |
| Cooking start time | "Start cooking at 5:45 for 6:30 dinner," from prep time. v1: see Cooking start time (#55) | 2 |
| Kitchen equipment | Household owns an air fryer, Instant Pot, grill; filter suggestions. v1: see Kitchen equipment (#55) | 2 |
| Dinner jobs | Optional rotating helper tasks (set the table, dishes). v1: see Dinner jobs (#50) | 2 |
| Change history and undo | "Dad swapped Tuesday to tacos"; undo a night's last change. v1: see Change history and undo (#57) | 2 |
| Calendar awareness | With permission, read the family calendar on-device and pre-mark busy nights as rushed; nothing leaves the phone | 3 |
| Picky-eater wins | "Nora tried 3 new dishes this month"; celebrates trying, not just liking | 3 |
| Dinner memories | Photo timeline of family dinners and a yearly recap | 3 |
| Budget awareness | Weekly spend from receipts; optional lean-week mode | Later |

## Risks, privacy, and outliers

As of 2026-10-25: Texas age-assurance rules and the amended COPPA rule are both in force, so age and consent handling belong in Phase 0, not launch week. Get a legal review before launch.

**Simplify for v1**

- Build all 12 notifications, but only 4 are on by default: plan set, prep reminder, day-of check-in, after-dinner prompt. The rest ship off and can be turned on in settings.
- Settings: presets plus advanced controls; any advanced control that can wait is flagged during build rather than cut.
- Pantry: manual in/low/out staples; receipt-driven inventory in Phase 3.
- Owner is a billing flag on a guardian, not a separate permission set.

**Security**

- Texas App Store Accountability Act: for new Texas Apple Accounts since June 4, 2026, developers handle age assurance, parental consent for minors under 18, significant-change determinations, and consent revocation. Use the Declared Age Range API, PermissionKit Significant Change API, StoreKit age rating, and server notifications ([source](https://9to5mac.com/2026/06/03/apple-says-texas-app-store-age-assurance-rules-start-tomorrow-after-court-ruling/)).
- Invite codes: single-use, expiring, rate-limited, unguessable.
- RLS tests for role escalation and editing others' allergies.
- Strip location and other metadata from every uploaded photo.
- Private storage buckets with short-lived signed URLs (15 minutes). Each household has its own folder: members read it, planners add photos. Photos are re-encoded on the device, which drops location and camera details, before upload.
- Recipe-fetch Edge Function blocks internal addresses (SSRF) and sanitizes HTML.
- No allergy details or names of absent kids in lock-screen notification text.
- Sign out of all devices (Family tab) ends every session at once: the database checks each request's session, so other devices lose access immediately rather than when their token expires. Removing a member unlinks their account and ends their access immediately.

**Privacy**

- Amended COPPA rule, compliance date April 22, 2026: written data-retention policy with a time period; new parental consent for material privacy changes ([source](https://toyassociation.org/PressRoom2/News/2026-News/updated-coppa-rule-requirements-take-effect-april-22.aspx)).
- **Kids on their own devices:** a parent consents in the kid's invite (logged with who, when, and the wording version) before a kid can join; withdrawing consent (member detail) signs the kid out at once. Claiming reads only the age band from Apple's Declared Age Range API, never a birthdate, and a minor's account can't claim an adult profile (#88).
- **Retention policy** (for the privacy notice, and for legal review: erasing a withdrawn kid's own ratings is a hard delete, the one exception to "never hard-delete" besides deleting the household; kept if the legal review agrees, decided 2026-10-28): deleting the household erases everything at once; a removed kid's profile is anonymized after 12 months (first name becomes "Former member", avatar and allergies deleted, ratings kept as anonymous history; their part of saved schedules goes when they're removed). When a parent withdraws a kid's own-device consent and doesn't give it again, what the kid added themselves (requests, ratings, comments, list items) and their age band are erased after 30 days; the parent-entered profile (name, avatar, allergies) stays while they're in the family. A daily job enforces both. The notification log keeps eight weeks for everyone, and a removed kid's or a withdrawn kid's rows go with the rest.
- **Legal review** happens before external TestFlight (founding families); internal TestFlight with our own family can go ahead first.
- Allergies are consumer health data in some states (e.g. Washington's My Health My Data Act): explicit opt-in built into the allergy step (Agree and save is the opt-in, logged with who, when, and the wording version shown; the sample family logs its own version, since nobody read the sentence). Only guardians opt in or revoke; revoking erases the data. `consents` is the gate, one active row per household. `consent_agreements` is the record: one row for each parent and wording, added each time someone agrees (#47), so a second parent, a new wording, or a real parent agreeing in a sample family is written down. Clearing a person's allergies never needs consent, so a parent can always delete them.
- Apple: in-app account deletion with Sign in with Apple token revocation, privacy manifest, accurate privacy label.
- v1 account deletion and export (#29): Delete my account is in Family, Your data, and on the first screen before a household exists. For the owner the button says **Delete my account and household**, because the household goes with it. It says what will happen, then the person confirms with Apple. The fresh authorization code lets the delete-account Edge Function revoke Foon's Sign in with Apple token. If Apple refuses, or the code is from a different Apple ID than the account's, nothing is deleted. Then:
  - the owner's household is erased with everything in it, photos included (ownership can be transferred first to keep it); everyone else keeps their own account;
  - another adult's profile is removed and anonymized at once ("Former member"; allergies, settings, and their part of saved schedules deleted; ratings and cook history kept as anonymous history);
  - a kid's account is unlinked, their comments are cleared, and the profile their parents entered stays, with their ratings.
  The auth account goes last, and the device signs out and wipes its offline cache. Other family members' devices wipe theirs the next time they find no household (#110). Planners can export the household as a JSON file (meals, ingredients, sides, items, traditions, plans, nights, attendance, saved schedules, lists, members, allergies, consents and who-agreed records); account ids and invite codes are left out.
- v1 Delete household (owner only, Family → Your data): erases the household and everything in it, photos included, for everyone, and every account stays. Each device then finds no household, wipes its offline cache, and shows start or join a household. A real household needs its name typed to confirm (with Export offered first); a sample family doesn't. A household made with "Load a sample family" is marked (`settings.sample`), and Family offers **Start your real family**, which is Delete household for the sample. On the server, one `erase_household` does the erase for both this and account deletion: a migration that adds a household table adds its delete there; pgTAP seeds every household table and checks none keeps rows after an erase. The typed name is the confirmation (no fresh Apple sign-in, unlike account deletion). The sample shortcut applies only while nobody else in the household has their own account; otherwise it's an ordinary Delete household. After the delete, this device goes straight to start or join; other members' devices find no household the next time they load it.
- Plan activity (#57) keeps eight weeks and is then deleted by the same daily job. It names people by their profile, so someone removed reads "Former member." Entries a withdrawn kid made themselves go with their other data. Delete household erases it, and export includes it.
- No tracking and no ad SDKs, so no App Tracking Transparency prompt. Market it.
- Delete receipt images after parsing. US-only launch at first.
- Imported recipe instructions stay private to the household; never shared across families or added to the catalog.

**Third-party services**

| Need | Choice | Note |
| --- | --- | --- |
| Errors and crashes | Sentry | iOS and Edge Functions; PII scrubbing on |
| Product analytics | TelemetryDeck or PostHog | Anonymized; no personal data |
| Subscriptions | RevenueCat (consider) | Entitlements, webhooks, founding offers; check pricing |
| Email | Resend | Adults only; see below |
| Landing page and waitlist | Nuxt on Vercel | Founding-family signups |

**Email (Resend), adults only.** Owner welcome, invite fallback for adults, subscription and deletion receipts, optional weekly plan email for planners, opt-in founding-family updates (CAN-SPAM). Later: inbound address for forwarded digital receipts. Register the sending domain with Apple's private email relay service or emails to Sign in with Apple relay addresses will bounce.

**Outliers to design for**

- Shared custody: recurring away patterns (every other week). v1: see Repeating time away (#49).
- Split dinners: two seatings in one night. Data model only (#49), no UI, and nothing plans with it: `plan_nights.second_seating_time` (null is one seating) and `night_attendance.seating` (1 or 2, everyone 1). It covers when and who, one dish a night; a different dish for the second seating would need a column of its own, and a list to match. Nothing writes either yet: no grants, so `create_week`, attendance and older apps are as they were.
- Babies and toddlers: "eats separately" flag, excluded from ratings and votes. v1: see Eats separately (#49). The tonight poll isn't built (#43); it reads the flag when it is.
- Recurring household food rules (no meat on Lent Fridays). v1: see Food rules (#49). Kosher and halal aren't offered: a name-based filter can't honestly promise them.
- Any household shape: single parent, couple, roommates, multigenerational, 8+ members.
- Fewer than 7 library meals: fill what's possible and suggest catalog dishes. (v1, #30: Build my week fills what it can without repeating a dish and leaves the rest open; This Week then shows, for the nights nothing fit, "Your library has N meals" (or "Nothing fit N nights" when the rules, not the count, left them open) with three popular starter dishes to add and Browse ideas.)
- Households of one and of eight or more plan like any other (#30). A night nobody's home gets no dinner (a "Nobody's home" chip, nothing on the list; Swap can still plan one). A big family's day card shows six avatars, whoever's away first, and "+N" (VoiceOver and the night's detail list everyone).
- Lapsed subscription: read-only, never delete history.
- Owner transfer and clean removal of an adult when families change.
- Planners can hide a comment. v1: see Hiding a comment (#49).
- All copy as localizable strings from day one; Spanish later.

## Build plan

Build everything, in order: Phase 1 (the Sunday flow) is what to sit down with your wife and refine first, while later phases are built and adjusted around her feedback.

**Phase 0: Foundation**

- [ ] Supabase project, schema, and row-level security by household
- [ ] Sign in with Apple; household creation; member profiles, roles, away status
- [ ] iMessage invites with link plus code; claim-a-profile flow
- [ ] Starter pack data: about 50 dinners with ingredients, tags, and prep steps
- [ ] SwiftUI app shell and SwiftData offline cache

* [ ] Age assurance and parental consent (Declared Age Range API, PermissionKit, consent logging)
* [ ] Storage security: private buckets, signed URLs, photo metadata stripping
* [ ] Security hardening: invite code limits, role-escalation RLS tests, sign out everywhere

**Phase 1: Sunday flow (show this first)**

- [ ] Onboarding: pick starter dishes, add family, invite
- [ ] Meal library: quick add, copy and tweak, recipe-site link import, archive
- [ ] Weekly plan: nightly attendance from defaults, night effort, event nights
- [ ] Build my week algorithm; edit, lock, shuffle, approve
- [ ] Weekly shopping list generated from the plan; check-off with offline sync
- [ ] Success test: download to first plan and list in under 15 minutes

* [ ] Observability: Sentry with PII scrubbing; TelemetryDeck or anonymized PostHog; privacy manifest
* [x] Account deletion (with Sign in with Apple token revocation) and household data export (#29)
* [ ] Edge cases: fewer than 7 meals, 1-member and 8+ member households, localizable strings

- [ ] Standing traditions (recurring nights)
- [ ] Side dish pairings
- [ ] Non-food items, item notes and brands on lists

**Phase 2: Family loop**

- [ ] Idea inbox and requests (dated and someday)
- [ ] Share Sheet extension (links, screenshots, PDFs, text)
- [ ] Day-of check-in and after-dinner confirm, reactions, leftovers, who cooked
- [ ] Dislike rules, favorites, trials, cook tally, Thanks chef, pass the phone
- [ ] Tonight poll and pivots (quick list gaps, move bumped meals)
- [ ] Keep-on-hand staples and backup dinners; quick list with urgency
- [ ] Prep reminders; allergies and dietary flags; serving notes; cook mode
- [ ] Notification settings, presets, budgets, ignore handling

* [ ] All 12 notification types built; 4 on by default, the rest off in settings
* [ ] Transactional email with Resend, adults only; Apple private relay domain registered
* [ ] Household shapes: recurring away patterns, eats-separately flag, recurring food rules, two-seating data model, hide comments

- [x] Claim a night and dinner jobs (#50)
- [ ] Heading to the store broadcast
- [ ] Vacation or pause mode; season templates
- [ ] Cook once, eat twice; freezer stash
- [x] Seasonal weighting and variety nudges in the algorithm (#54)
- [ ] Cooking start time nudge; kitchen equipment filter
- [x] Change history and undo (#57)

**Phase 3: Wow layer**

- [ ] On-device AI features and the household AI job queue, with non-AI fallbacks
- [ ] Receipt scanning (photo and forwarded email)
- [ ] Widgets, Siri and App Intents
- [ ] Weekly recap; planner engagement view
- [ ] Polished onboarding that demonstrates the AI features

* [ ] Calendar awareness (EventKit, on-device, read-only)
* [ ] Picky-eater wins; dinner memories timeline and yearly recap

**Phase 4: Launch**

- [ ] StoreKit products (standard and Founding Family) with household entitlement
- [ ] Privacy policy, terms, App Store privacy label; legal review (COPPA, allergy disclaimer, the allergy consent wording, the household time zone, how long hosted backups keep deleted data, and the hard delete of a withdrawn kid's own ratings)
- [ ] TestFlight with our family, then the founding 50 households (flagged on the server)
  - Founding flag (#37): while `app_config.founding_open` is on (both betas), a trigger flags every new household `founding = true`. Clients can't read the switch, flip it, or set the flag. At launch a migration turns it off, and flagged households keep it. There's no automatic cap at 50: we close it by hand.
- [ ] Enroll in Apple's Small Business Program; App Store submission

* [ ] Written data-retention policy; allergy data opt-in consent; receipt images deleted after parsing

**Later.** Budget awareness and lean-week mode from receipts; taste-based recommendations from long-term ratings history ("everyone loved the chicken and pork dishes; here's a new one similar to both"), surfaced in New finds; shopping insights; bring-your-own AI via MCP; web page for non-iPhone members; multiple households per person; per-night scaling of weight-based items; retailer partnerships.

## Brand: Foon

Working name: **Foon**, a real word for a spork (fork plus spoon). The tool is the hybrid: just as a foon does the job of a fork and a spoon, Foon does the job of a meal planner, a family vote, and a shopping list in one. Families are just families; never call them hybrid families. Short, playful, curiosity-driven; the tagline does the explaining.

**Recommended set**

| Use | Line |
| --- | --- |
| Main tagline | Different tastes. Same table. |
| App Store name | Foon: Family Dinner Planner |
| App Store subtitle | Plan, vote, shop. Together. |
| Marketing to the planner parent | Take dinner off one person's plate. |
| Origin story line | Spoon + fork = foon. Parents + kids = dinner. |

**Other tagline candidates**

- Picky kids. Busy parents. One dinner.
- One tool for the whole dinner.
- Dinner, decided together.
- Everyone brings something to the table.
- Because "I don't care, whatever you want" isn't a plan.
- The family dinner planner everyone helps with.

**Icon concepts**

1. A simple spork silhouette on a bold, warm background.
2. The spork's four tines as rounded heads of different heights (parents and kids), the bowl as the table holding them together.
3. The "oo" in the Foon wordmark drawn as two plates seen from above, giving the word a face.

**Voice.** Warm, a little cheeky, never preachy. Example: "Owen wants steak. Nora wants anything but chicken. Foon's on it." In-app language can play along: "foon it" to add a request, "this week's top foon."

**Colors.** Tomato red or paprika orange primary, cream background, deep green accent.

**Name checks still needed.** USPTO trademark search, App Store name availability, domains (foon.app, getfoon.com). Known prior use: "Foon" is the fictional setting of the podcast Hello from the Magic Tavern ([source](https://en.wikipedia.org/wiki/Foon)). Backups considered: Dollop, Famished, Wishbone, Mixed Plate, Sporkly. Avoid "Sporkful" (an established food podcast).

## Business model and launch

One subscription per household: $5.99 a month or $49.99 a year after a 30-day free trial. No feature tiers; future add-ons decided later.

**Founding families.** Founding households use Foon free during the TestFlight beta, then get 50% off the annual plan ($24.99 a year) at launch, locked for life with no price increases. Flagged on the server; at launch they see a separate Founding Family product. After 50 families or a year, new families pay standard pricing, ideally with new features to justify it.

**Market context.** Comparable apps: Plan to Eat at $49 a year or $5.95 a month ([source](https://learn.plantoeat.com/doc/how-much-does-plan-to-eat-cost)); Ollie, an AI family planner, at $9.99 and $79.99 tiers ([source](https://apps.apple.com/us/app/ollie-ai-family-meal-planner/id6480014476)). Several early family-voting apps exist (WhatWeEating, Sorted, BiteBallot, Agent Chef); the differentiator is the full loop, not voting.

**Entity.** Published under The Recruiting Compass LLC's existing Apple developer account; consider a registered trade name for the app.

**Open questions**

- Confirm Foon name availability (trademark, App Store, domains)
- Recruit founding families: personal network first (TestFlight invites), then social media and the landing page waitlist
- Where to recruit the founding 50 families
- Starter pack contents and tagging
- Default notification times (what each preset sends is decided above)

**Marketing presence.** Landing page (Nuxt on Vercel) with waitlist, privacy, terms, and support pages. Social accounts reserved under one handle on Instagram, TikTok, Facebook, and X, ideally the same day as the name check. Domain check on 2026-10-25: foon.app, foon.com, foon.co, and foonapp.com are taken; getfoon.com, usefoon.com, and foon.family are available.

**Success metrics: shown to families.** Honest, positive stats on a family stats card and in the recap:

- Dinners planned together this month
- Ideas from someone other than the planner ("12 of 20 dinners were someone else's idea")
- Nights cooked by someone other than the usual cook
- Family dinners at the table
- New dishes tried
- Estimated planning time saved, clearly labeled as an estimate

**Success metrics: internal.** North star: share of dinners where someone other than the planner contributed (request, vote, claim, or cook). Also: onboarding completion, time to first plan, weekly active households, plans approved per week, after-dinner response rate, contributors per household, shopping trips completed, week-1 and week-4 retention, trial-to-paid conversion. All anonymized; no individual tracking.

**Before building much:** run a two-week shared-note trial (assigned nights, requests) and show your wife the Phase 1 prototype for feedback.
