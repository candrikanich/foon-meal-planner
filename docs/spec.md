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

**Family tab.** Header with household name, emoji or photo, Founding Family badge, and subscription status (owner). Member rows show avatar, name, role, and status (Home, Away, Invite pending), with Add member and Invite. Member detail: adult or kid, guardian, and role (guardians edit), Home or Away with optional return date (auto-flips back, with a heads-up to plan their favorites), usual weekday schedule (everyone edits their own; guardians can override), allergies and dietary preferences (guardians edit; everyone sees), Remove from household (guardians), taste profile of favorites, dislikes, and serving notes (visible to everyone), cook tally, and per-member notification preset. Household rhythm and planning mix defaults (planners), notification presets, show tips again, plain-English privacy summary with data export and delete household, and subscription (owner).

**Minimal data.** Household name (last name or nickname), first names, avatars. No birthdays, phone numbers, photos, or location. Keep the app a parent-run household app, not in the App Store Kids category. COPPA applies if users under 13 are known; get a legal review before launch.

**Allergies and dietary preferences**

Important, never a burden. Families without allergies never see allergy UI; families with them tell the app in about 30 seconds.

- **One question in onboarding:** "Does anyone have food allergies?" No is one tap and the topic never comes back. Yes opens one screen: a single plain sentence ("Foon keeps these in your household to flag dishes. Never shared, never sent off-device.") above each person with tappable chips. Tapping the first chip is the opt-in; there is no separate consent step.
- Standard chips: the 9 major US allergens (milk, eggs, fish, shellfish, tree nuts, peanuts, wheat, soy, sesame) plus Other with free text. Each maps to a keyword list (casein and butter map to milk, tahini to sesame).
- Guardians add and change allergies later from member detail, using the same chips. Everyone in the household sees them.
- **Flag, don't filter:** affected dishes (starter pack included) stay available with a flag such as "Contains milk (Nora)." Flags show in the library, on day cards, and on the shopping list ("Cheese: get dairy-free"). Planning is never blocked by an allergy, and allergies never trigger push notifications.
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
4. **From a photo, screenshot, or PDF:** text recognition, then ingredient parsing (AI on capable devices).

**Share Sheet extension (v1).** One share target for everything: recipe links and videos go to the library or idea inbox, screenshots to recipe capture, PDFs to import, plain text ("milk, eggs, bread") to the quick shopping list. Social posts (Instagram, TikTok, Facebook) fall back in order: parse the caption, then a screenshot of the ingredients, then save as an idea with title and link.

**Quantities.** Recipes scale once, at import, to household size. Short-handed nights don't rescale; they predict leftovers instead. Per-night scaling of weight-based items (meat, produce) is a later option. Household size updates automatically with away status.

**Removing.** Swipe to archive: gone from suggestions, recoverable, history kept. Nothing is hard-deleted. Dislike rules retire dishes automatically.

**Library screen.** Search, a prominent Add button (quick add, link, photo, paste), filter chips (Favorites, Quick, Trying, Backup dinners, Allergy flags, Archived), a two-column photo grid with effort, made-by, and allergy indicators, and sorts (Haven't had in a while, Most made, Family favorites, Recently added).

- Filters are one at a time; with none chosen, the grid shows meals in rotation (active and trying). Archived also lists retired dishes.
- Search matches meal names and ingredients, ignoring case and accents. Matching starter dishes not yet in the library appear below the family's own ("From Foon's ideas").
- History (times made, last made) counts past nights of approved plans until dinners are confirmed (meal logs, M2). Haven't had in a while puts never-made dishes last; they're new, not forgotten.
- Favorites and the Family favorites sort need ratings (M2); until then the Favorites chip shows an empty state.
- Long-press: Archive, or Back in rotation for archived meals (planners only). Plan it joins the menu with This Week (#23).
- Browse ideas lists the catalog by category; planners copy a dish into the library with one tap, and adding it again returns the copy already there, even a retired one: a dish the dislike rule retired stays retired.

**Meal detail.** Hero photo with "Replace with yours"; tags and allergy flags (Make it safe comes later; see Allergies); every family member's current verdict, visible to all; history and frequency ("Made 8 times, about every 2 weeks"); editable ingredients with Add to list; optional recipe steps and source link; prep steps; comments; per-person serving notes ("Nora: keep everything separate before mixing"), shown on day cards and in cook mode when that person is home; actions Plan it, Copy and tweak, Archive.

- v1 (#19): ingredients are edited as lines (amount and name), typed or pasted naturally with autocomplete from the library. New items take the starter pack's category for the same name, else Other. Saving writes the meal and its lines together.
- Add to list puts an ingredient (or all of them) on the quick list; anyone in the family can, offline too.
- Copy and tweak makes "Name (copy)" with the recipe, prep, and ingredients, but not the photo or the catalog link, and opens the editor on it. Retired meals aren't copied, so the dislike rule holds.
- Steps are optional, one per line; typed numbering ("1.", "Step 2:") is dropped. Links must be web addresses; "example.com" gains https.
- Verdicts, comments, serving notes, and frequency ("about every 2 weeks") need ratings and dinner logs (M2). Plan it joins with This Week (#23).

**Frequency awareness.** Overuse nudges ("Tacos 3 times in 2 weeks"), neglect nudges ("No pot roast in 7 weeks"), and recap callouts make the log the planner's memory.

**Cook mode (Phase 2).** One step per screen, timers, screen stays awake, serving notes surfaced; supports beginner cooks.

**Idea inbox.** Anyone can request a dish. Dated requests ("steak Friday, my night off") land on that week's plan; "someday" wishes sit in a backlog the planner pulls from. New dishes start tagged as trials until everyone has reacted.

**Ideas tab.** Sections: For this week (dated), Someday, New finds (shared recipes processing or awaiting review). Cards show requester, photo or link preview, note, +1s from others ("me too"), and status (Waiting, Planned for Friday, Tried). One "I want..." button: pick from library, share or paste a link, snap a photo, or type freely, with an optional night.

**Inbox rules.** No hard decline and no request limits. Planner actions: Plan it, Save to library, Not this week (carries forward), and Save for a special occasion (resurfaces on birthday or celebration nights: "He's wanted crab legs since March"); plain archive for clutter. Unplanned dated requests move to Someday. Requests with multiple +1s get top priority in Build my week, on a night everyone who wants it is home. Requesters are notified when their idea makes the plan.

## Weekly planning

The planner taps "Build my week," gets a solid draft, and shapes it. The algorithm is plain code and works on every device; AI is an optional layer.

**Household planning settings.** Planning day and time (ours: Sunday morning, before shopping), week start (the shopping day), new dishes per week, takeout nights, leftover nights, minimum days before a repeat (e.g. 10), dinner time per night.

- Stored in `households.settings` (#22), every key optional with a default: `week_start` (ISO weekday, default 7 = Sunday), `dinner_time` ("18:00"), `new_dishes_per_week` (1), `takeout_nights` (0), `leftover_nights` (1), `repeat_window_days` (10). Out-of-range values fall back to the default.

**Attendance per night.** Each night has a checklist of who's expected home, pre-filled from per-person recurring defaults ("Owen works Mon to Thu") and edited for exceptions. Planners own attendance; real-life changes happen by text and get reconciled by the day-of check-in and the after-dinner prompt.

- v1 (#22): `members.attendance_defaults` is `{"usually_away": [ISO weekdays]}`, set on the member's profile ("Usually home for dinner"; everyone edits their own, parents anyone's). Starting a week (`create_week`) makes seven nights from the shopping day at normal effort and the household dinner time, with a row for everyone not removed: out on their usual nights away, and away members out until their return date (all week without one). Someone added later gets their nights filled in when a planner next opens the week. A week starts on the shopping day; a dinner time that isn't HH:MM falls back to 18:00. Tapping an avatar toggles it; tapping the effort chip cycles normal, rushed, full evening, event.

**Night effort.** Each night is set to full evening, normal, or rushed. Rushed nights only get quick meals, takeout, or leftovers.

**Build my week algorithm**

1. **Lock** what's decided: dated requests, event nights, pinned meals, standing traditions.
2. **Fill special slots:** leftover night after a big-batch meal; takeout on the busiest night; new dishes on full-attendance nights.
3. **Filter candidates per night:** drop dishes inside the repeat window or snoozed; dishes disliked by anyone home that night; retired dishes; non-quick meals on rushed nights; grill or advance-prep meals where they don't fit.
4. **Score and draw** with weighted randomness: days since last made (higher is better), a favorite of someone home (big boost), ingredients already on hand (boost), overall thumbs-up (small boost).
5. **Planner edits:** swap, lock, shuffle any unlocked night, approve. Approval generates the weekly shopping list.

v1 rules (#24, `Foon/Core/Planning/BuildMyWeek.swift`, a pure function of the inputs and a seed):

- **Kept nights** (never changed): locked, event, nights before today, and a dated request's night. Requests skip the filters because the family asked out loud. Kept nights count toward the takeout, leftovers, and new-dish settings, so a mid-week rebuild doesn't add extras.
- **A new dish** is a meal on trial. A dish that's never been made isn't new (onboarding copies dishes the family already makes); it's just due for a turn. New dishes are capped at the setting and go to full-attendance nights first; past the cap only when nothing else fits.
- **Takeout** goes on the busiest night: rushed first, then most people home, then not the shopping day, then earliest. **Leftovers** follow a big-batch meal (tagged leftovers) in the week, else land on the most rushed night.
- **Filters:** in rotation (not archived or retired), not snoozed, not already in the week, outside the repeat window for that night, not disliked by anyone home, quick only on rushed nights, and enough lead time for advance prep (thaw first counts as 24 hours; a night has 24 hours per day from today plus about 8 before dinner today). Allergies never filter; they flag.
- **Score:** days since last made for that night (1–90; never made counts as 90), times boosts for a favorite of someone home, ingredients on hand, and family likes; drawn with a seeded generator, so the same inputs and seed give the same week on every device.
- **Shuffle** re-rolls one unkept meal night from the saved week, keeping its kind: a big-batch night stays a big batch, a trial slot stays trial first. Quick-pick nights are changed with Swap, not shuffle.
- **Reasons:** a request, a favorite of someone home, something new, quick for a rushed night, uses what's on hand, the family likes it, "Haven't had it since yesterday / in N days / in a week / in N weeks", or "Due for a turn".

**AI layer (capable devices).** Reads the same inputs plus patterns scoring can't express ("soup when it gets cold," "Thursdays have been leftovers lately") and explains picks in plain language.

**Family polls during planning.** Optional: "Everyone's home Wednesday. Breakfast for dinner, tacos, or eat out?"

**Tonight poll.** When there's no plan or it falls apart, anyone starts a poll among people home tonight: e.g. takeout, hot dogs, leftovers, or a backup dinner in stock. Closes at a set time; no vote counts as abstaining.

**Pivots.** Swapping a night checks the new meal's ingredients against what's on hand and adds gaps to the quick list. Bumped meals offer to move to another night so ingredients don't go to waste.

**Swap sheet.** Three suggestions with reason chips; a quick-pick row of Leftovers, Takeout, Eat out, and Fend for yourselves (everyone makes their own); then search the library or quick-add a dish. The Leftovers option lists which meals have leftovers and how old they are; no quantities. Takeout and eating out are logged without capturing where.

- v1 (#25): suggestions use Build my week's filters and weights for that night (never a dish already in the week; trial dishes only within the week's budget), with "More ideas" to draw again. Quick picks: Leftovers, Takeout, Eat out, Fend for yourselves, Freezer raid. Searching shows your meals, then Foon's ideas (added to the library when picked), then "Add … as a new dish." The planner's pick locks the night so Rebuild keeps it; "Leave it empty" clears and unlocks it. Any night can be swapped, locked ones included; on a past night (logging what was eaten) suggestions ignore prep time and the repeat window. Typing an archived meal's name offers to restore and plan it rather than adding it again. The leftovers list with ages needs dinner logs (M2).

**Fridge cleanout.** Leftovers carry their age. The app can suggest a leftovers night when several are piling up and flag old ones: "Monday's tacos are 4 days old. Use or toss?"

**Day cards.** Each night is a card holding everything: effort chip, tap-to-toggle attendance avatars, meal with reason chip, inline lock, shuffle, and swap, and badges. Cards stack like Apple Wallet with tonight on top. The same card is the This Week view and the planning view; an empty card offers Pick for me or Choose. Kids see cards read-only with vote and suggest-a-swap. No family approval step: the planner approves and the list is built.

- v1 This Week (#23): tonight's card on top, then the rest of the week; past nights fold into "Earlier this week." With no week yet, planners get Build my week (or start with empty nights) and members get "Add your requests." A started week that's still empty offers Build my week; a partly planned one shows how many nights are open with Fill remaining nights, which drafts only empty nights. Rebuild unlocked nights redraws everything not locked; a draft that finds nothing for a night never clears what it had, and the save refuses a night another planner has locked since. Each card has lock and shuffle (Pick for me on an empty night; quick-pick nights change through Swap). Tapping a card opens the night: meal and sides, dinner time, effort, who's home, and lock. Reason chips are saved with the night so everyone sees them. Allergy badges name only who's home that night, and the first prep step shows as a badge. The cart button shows open list items and opens Lists.

**Event nights.** Holidays and dinner parties are marked on the plan and skipped by voting and ratings. Leftovers from them are still logged.

## After-dinner loop

The plan is the log by default; one notification per person confirms it, rates it, and captures leftovers.

**The prompt.** About an hour after that night's dinner time, everyone expected home gets: "Mac and cheese tonight?" with Favorite, Good, Not for me, Tired of it, "We had something else," and "Wasn't home." Any reaction confirms the meal and records that person's rating in one tap. If anyone picks "something else," they correct the log and everyone's prompt updates. No cook assignment needed.

**First responder extras.** Leftovers: yes or no, pre-filled with the app's prediction when someone was out. Quantity isn't tracked. Who cooked: tap a family face (optional). An optional "it was off tonight" checkbox separates a bad night from a bad recipe, plus an optional one-line comment.

**No responses.** Auto-confirm overnight, marked unverified so the planner can spot gaps.

**Prompt design.** A rich notification card (long-press, no app open needed): one tap on a reaction saves, no submit button. First responder gets pre-filled Leftovers and Who cooked rows. "We had something else" opens a mini swap sheet, then asks whether to move the planned dish to another night. A missed prompt shows as a slim card on This Week until the next evening. Comments and "it was off tonight" live one tap deeper. Reactions can be changed for 24 hours, then lock into history.

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
- Dislikes never expire. Ratings are family-only; guests don't rate.

**Transparency.** Reactions are visible to the whole family. Always rate the dish, never the cook; the prompt asks about the food ("How was the chicken thing?").

**Cook credit.** Every logged dinner records who made it, with no rating attached. A monthly "cooked this month" tally and a one-tap "Thanks, chef" make contributions visible and encourage more cooks. Beginner-friendly tags give kids a shortlist they can make on their own.

**Pass the phone.** At the table, everyone rates in about 20 seconds on one device; a natural ritual and a fallback for kids who ignore notifications.

## Shopping and pantry

The plan produces one weekly list; pivots and running-out moments produce the quick list. Store-agnostic: no store setup or store logic.

**Weekly list.** Generated from the approved plan's ingredients, minus what's on hand, merged with low or out staples. Designed so one big trip covers the week.

**Quick list.** Fill-in trips during the week. Fed by pivots ("mac and cheese needs milk"), staple taps, and shared text. Items carry urgency ("for tonight's dinner" vs "whenever"). Duplicates merge: milk from a pivot and milk from a tap show once.

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

| Notification | Who | When | If ignored |
| --- | --- | --- | --- |
| Requests open | Everyone | Evening before planning day | Pause for that member after 3 ignored weeks |
| Time to plan | Planners | Planning day and time | One follow-up, then an in-app banner |
| Plan's set | Everyone | On approval | Nothing |
| Prep reminder (thaw, marinate, start slow cooker) | Planners, or whoever's home | Relative to dinner time | One follow-up, then drop |
| Day-of check-in, with dinner preview | Everyone expected home | Adult-set time, default after school | No answer means home |
| No plan tonight | Adults | Afternoon | Nothing |
| Tonight poll | Whoever's home tonight | When started; closes at set time | No vote means abstain |
| After-dinner confirm and rate | Whoever was expected | About an hour after dinner time | Downshift to weekly roundup after 3 ignored nights |
| Allergy flag | Planners | Shown in-plan until acknowledged | Never a dismissible push |
| Urgent list item | Adults | When added ("milk for tonight") | Nothing; ordinary staple taps notify no one |
| New requests | Planners | Batched digest | Nothing |
| Weekly recap | Everyone (optional) | After the week | Nothing |

**Action buttons.** Prep reminders offer Done, Remind me in an hour, or Swap tomorrow's dinner. The day-of check-in is home or not home; planners hear only about changes, and the app reacts (leftovers expected, offer a swap if the absent person was the reason for the pick).

**Keeping kids engaged without nagging**

- **Budget:** a household cap on pushes per member per week (default around 4 to 6 for kids).
- **Downshift, don't stop:** nightly ratings become a weekly roundup, then a gentle "want these back?" a week or two later.
- **Show influence:** "Your steak request made Friday," "Your vote broke the tie."
- **Pass the phone** at the table as the fallback.
- **Planner engagement view:** a quiet note like "Owen hasn't sent requests in 3 weeks" so a parent can nudge in person.
- No streak shaming, ever.

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

**Backend.** Supabase Postgres with every table scoped by `household_id` and row-level security from day one; Realtime for live list check-offs; Edge Functions for scheduled notifications (APNs), recipe-site parsing, and invite codes; Storage for receipt images if retained.

**Why not CloudKit.** Relational queries (ratings by person, dish, and night against attendance), realtime collaboration, and a possible future web page. Trade-off: owning hosting cost and the privacy story.

**Data model sketch**

| Table | Key fields |
| --- | --- |
| households | name, owner, settings (JSON), founding flag, subscription status |
| members | household, first name, avatar, adult or kid, guardian, role (planner, member), status (active, away, removed), user link (null until claimed), attendance defaults |
| allergies | member, category, custom text (guardians edit; needs allergy consent) |
| consents | household, member (kid, for parental), kind (allergy data, parental), granted by, granted at, revoked at, wording version; append-only |
| meals | household, name, servings, tags, prep steps, recipe steps, source URL, photo, made by, status (active, trial, archived, retired) |
| meal\_ingredients | meal, item, quantity (optional) |
| meal\_sides | meal, side meal or item, position |
| items | household, canonical name, category (groceries, household, personal care), keep-on-hand flag, stock state (in, low, out), note or brand preference |
| plans / plan\_nights | week start; per night: date, meal, effort, dinner time, locked, event flag |
| night\_attendance | plan night, member, expected, confirmed |
| meal\_logs | plan night, meal actually eaten, cooked by, leftovers, verified |
| reactions | meal log, member, reaction, off-tonight flag, comment |
| requests | household, member, meal or link, target date (optional), status |
| list\_items | household, item, list (weekly, quick), urgency, source, checked |
| polls / votes | household, night, options, closes at; member, choice |
| receipts / receipt\_lines | household, date, image; raw text, matched item |
| ai\_jobs | household, type, payload, status, claimed by device, result |
| notification\_log | member, type, sent, responded (drives ignore and budget rules) |

**Payments.** StoreKit 2 with server-side entitlement on the household. Two subscription products: standard and Founding Family.

## Family-life features

Every family is different; these are all in, each optional and off or unobtrusive by default, assigned to the phase where they fit.

| Feature | What it does | Phase |
| --- | --- | --- |
| Standing traditions | Recurring nights (Taco Tuesday, Pizza Friday) auto-fill each week unless swapped. v1: one per weekday, a library meal or quick pick with an optional name for the chip; planners set them from This Week → Traditions. Build my week lands them after dated requests (a request wins its night) and saves them locked; a meal no longer in rotation is skipped, and a tradition sits out a week when it's snoozed or someone home that night said "not for me" (the repeat window, rushed nights, and prep time don't apply, since it's chosen on purpose); quick-pick traditions count toward the takeout and leftovers settings. Swapping a tradition night changes only that week | 1 |
| Side dishes | Optional side pairings per meal (salad, garlic bread) so the list is complete. A side is a library meal (its ingredients join the list) or a simple item (added itself); one level, so sides of sides aren't followed. Shown on day cards ("with salad and garlic bread") and meal detail ("Goes with"); Copy and tweak keeps them. Archived meals can be sides; retired ones can't, and a side retired later drops off. Allergy flags include sides | 1 |
| Non-food items | Household and personal care items (paper towels, toothpaste) live on the same list, sorted after groceries in store mode, and can be keep-on-hand staples | 1 |
| Item notes and brands | "Vanilla yogurt, not plain," "store brand": a standing note per item (80 characters), set by anyone at home and shown with the item on meals, lists, and in store mode | 1 |
| Claim a night | Anyone taps "I'll cook Thursday"; voluntary, visible, feeds cook credit | 2 |
| Heading to the store | One tap tells the family to add items in the next 10 minutes | 2 |
| Vacation or pause mode | Skip planning, notifications, and lists for away days | 2 |
| Season templates | Save and switch attendance patterns (baseball season, school year, summer) | 2 |
| Cook once, eat twice | "Double it" plans the leftovers night; freezer-stash list of meals cooked ahead | 2 |
| Seasonal weighting | Grill meals rise in summer, soups and slow cooker in winter | 2 |
| Variety nudges | "Pasta 3 times this week"; no calorie or nutrition tracking, by design | 2 |
| Cooking start time | "Start cooking at 5:45 for 6:30 dinner," from prep time | 2 |
| Kitchen equipment | Household owns an air fryer, Instant Pot, grill; filter suggestions | 2 |
| Dinner jobs | Optional rotating helper tasks (set the table, dishes) | 2 |
| Change history and undo | "Dad swapped Tuesday to tacos"; undo recent changes | 2 |
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
- **Retention policy** (for the privacy notice): deleting the household erases everything at once; a removed kid's profile is anonymized after 12 months (first name becomes "Former member", avatar and allergies deleted, ratings kept as anonymous history). When a parent withdraws a kid's own-device consent and doesn't give it again, what the kid added themselves (requests, ratings, comments, list items) and their age band are erased after 30 days; the parent-entered profile (name, avatar, allergies) stays while they're in the family. A daily job enforces both.
- **Legal review** happens before external TestFlight (founding families); internal TestFlight with our own family can go ahead first.
- Allergies are consumer health data in some states (e.g. Washington's My Health My Data Act): explicit opt-in built into the allergy step (adding the first allergy is the opt-in, logged with who, when, and the wording shown). Only guardians opt in or revoke; revoking erases the data.
- Apple: in-app account deletion with Sign in with Apple token revocation, privacy manifest, accurate privacy label.
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

- Shared custody: recurring away patterns (every other week).
- Split dinners: two seatings in one night (design the data model now, build later).
- Babies and toddlers: "eats separately" flag, excluded from ratings and votes.
- Recurring household food rules (no meat on Lent Fridays, kosher, halal).
- Any household shape: single parent, couple, roommates, multigenerational, 8+ members.
- Fewer than 7 library meals: fill what's possible and suggest catalog dishes.
- Lapsed subscription: read-only, never delete history.
- Owner transfer and clean removal of an adult when families change.
- Planners can hide a comment.
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
* [ ] Account deletion (with Sign in with Apple token revocation) and household data export
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

- [ ] Claim a night and dinner jobs
- [ ] Heading to the store broadcast
- [ ] Vacation or pause mode; season templates
- [ ] Cook once, eat twice; freezer stash
- [ ] Seasonal weighting and variety nudges in the algorithm
- [ ] Cooking start time nudge; kitchen equipment filter
- [ ] Change history and undo

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
- [ ] Privacy policy, terms, App Store privacy label; legal review (COPPA, allergy disclaimer)
- [ ] TestFlight with our family, then the founding 50 households (flagged on the server)
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
- Default notification times and budgets for the Balanced preset

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
