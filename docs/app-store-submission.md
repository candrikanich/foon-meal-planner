# App Store Submission

Draft App Store Connect data for Foon, ready to paste. Verify field limits and the age-rating questionnaire in App Store Connect at submission time; Apple changes them.

## Listing

| Field | Value | Limit |
| --- | --- | --- |
| App name | Foon: Family Dinner Planner | 30 chars (27) |
| Subtitle | Plan, vote, shop. Together. | 30 chars (27) |
| Primary category | Food & Drink | |
| Secondary category | Lifestyle | |
| Keywords | meal plan,grocery,shopping list,recipes,menu,weekly,kids,picky eater,leftovers,pantry,cooking,vote | 100 chars (98); no words repeated from the name |
| Promotional text | Picky kids. Busy parents. One dinner. Plan the week together in minutes, build the shopping list automatically, and stop asking "what's for dinner?" | 170 chars |
| Copyright | 2026 The Recruiting Compass LLC | |
| Support URL | https://getfoon.com/support | Mailbox support@getfoon.com must exist |
| Marketing URL | https://getfoon.com | |
| Privacy policy URL | https://getfoon.com/privacy | Required. Today a plain-English summary; #67 replaces it with the full policy. Terms are at https://getfoon.com/terms (placeholder until #67) |

## Description (draft)

Dinner shouldn't be one person's job.

Foon turns "what's for dinner?" into a family effort. Everyone suggests meals, votes, and rates what they ate, so the person who plans dinner edits a plan instead of inventing one every night.

PLAN THE WEEK IN MINUTES
Tap "Fill my week" and Foon drafts seven dinners around who's home, how busy each night is, what your family loves, and what you haven't had in a while. Lock, shuffle, or swap any night.

THE WHOLE FAMILY HAS A SAY
Kids and partners request dishes, share recipes from any app, and vote. After dinner, everyone rates the meal with one tap. Rate the dish, never the cook.

SHOPPING, HANDLED
Approve your week and the grocery list builds itself. Store mode works offline, stays in sync when you split up in the store, and keeps staples like milk and bread from running out.

MADE FOR REAL FAMILIES
Allergy flags on every dish and the shopping list. Prep reminders to thaw the chicken. Leftovers nights, takeout nights, and "fend for yourselves" nights. Taco Tuesday on repeat.

PRIVATE BY DESIGN
No ads. No tracking. AI features run on your device, so your family's data never leaves your phone for AI processing.

One subscription covers your whole household. Try it free for 30 days.

Allergy flags are a helpful second set of eyes, not a guarantee. Always check labels.

## Subscriptions

| Item | Value |
| --- | --- |
| Subscription group | Foon Household |
| Monthly | $5.99, 30-day free trial |
| Annual | $49.99, 30-day free trial |
| Founding Family | Annual at $24.99 (50% off), locked for life; shown only to founding households (free during the TestFlight beta) |
| Display name | Foon Household |
| Description | Plan dinners together. Covers your whole household. |
| Review screenshot | Paywall screen (required per product) |

The paywall must show price, period, trial length, auto-renewal terms, and links to terms and privacy policy.

## App privacy (nutrition label)

Data used to track you: **None.**

| Data type | Collected | Purpose | Linked to user |
| --- | --- | --- | --- |
| Name (first names) | Yes | App functionality | Yes |
| Email address (Sign in with Apple, may be relay) | Yes | App functionality, account | Yes |
| Health (allergies) | Yes | App functionality | Yes |
| Photos | Yes (meal photos) | App functionality | Yes |
| Other user content (meals, comments, requests, receipt lines the family corrected, a dish's recipe lines queued for an AI tidy-up) | Yes | App functionality | Yes |
| User ID | Yes | App functionality | Yes |
| Purchase history | Yes | App functionality | Yes |
| Product interaction | Yes | Analytics | No (anonymized) |
| Product interaction (which reminders went out and were answered: kind, night, time) | Yes | App functionality | Yes |
| Crash and performance data | Yes | App functionality | No (scrubbed) |

Not collected: precise or coarse location, contacts, browsing history, search history, financial info, sensitive info beyond allergies, calendar data (read on device only, never collected), library photos shown in Dinner memories (read on device only, never uploaded or kept), receipt photos (read on device only, never uploaded or kept; what's kept is "Other user content": receipt lines the family corrected and the item each is).

AI recipe tidy-up (#59): no new data type. A device that can run Apple's on-device model tidies a shared recipe itself and sends nothing. Only on a device that can't, and only when a planner adds the dish, do the parsed recipe lines (title, servings, ingredient and step lines, never the raw screen text) and the source link go to the household's `ai_jobs` queue, for a planner's device in the family to structure. That's "Other user content", for App functionality, linked to the user, and not used for tracking. The lines are emptied from the job once it's done, failed or expired (3 days at most); the tidied recipe stays with the job until finished jobs are pruned 30 days on. No allergies or member data are ever in a job, and the model runs on the family's own devices, never a server.

**Permission prompts.** Camera (`NSCameraUsageDescription` in Info.plist, via `project.yml`): "Foon reads a receipt you photograph to mark what you bought. The photo stays on this device and isn't kept." Asked the first time someone takes a receipt photo (#61). Choosing a photo uses the system photo picker, which needs no permission.

Calendar awareness (#64): in App Privacy, don't add a calendar or "Other data" type for it. Apple counts data as collected only when it's sent off the device, and Foon reads event times on the device, keeps them in memory, and never sends, saves, or logs them. The permission is a separate matter from the label: the `NSCalendarsFullAccessUsageDescription` prompt ("Foon looks at your calendar on this device to spot busy evenings. Nothing from it leaves your device.") shows only when a planner turns on Family → Spot busy evenings. EventKit has no read-only level, so it asks for full access; Foon only reads. The Mac build adds the sandbox's calendars entitlement (`ENABLE_RESOURCE_ACCESS_CALENDARS`). EventKit isn't a required-reason API, so it adds nothing to a privacy manifest.

Dinner memories (#65, part 3): in App Privacy, the existing Photos row stays as it is (meal photos a planner adds); don't widen it for this. Foon reads library photos taken around dinner on the device, holds them in memory while the screen is open, and never sends, saves, or logs them, so Apple doesn't count them as collected. The `NSPhotoLibraryUsageDescription` prompt ("Foon shows your photos from around dinner, on this device only. It never uploads or saves them.") shows only when someone taps Family → Dinner memories → Show my dinner photos. Limited access works. The Mac build adds the sandbox's photos entitlement (`ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY`). PhotoKit isn't a required-reason API, so it adds nothing to a privacy manifest. The prompt isn't localized yet (no InfoPlist.xcstrings), like the other usage strings.

## Age rating

Target: the lowest available rating. Answer the questionnaire honestly: no mature content, no gambling, no web browsing, no public user-generated content. Family comments are private to a household with no public sharing or messaging strangers. Confirm the resulting rating in App Store Connect.

- Not in the Kids category.
- Texas age-assurance support (Declared Age Range API, PermissionKit) implemented before submission.

## Screenshots

| Device | Needed |
| --- | --- |
| iPhone 6.9-inch | Required |
| iPad 13-inch | Required if iPad is supported |
| Mac | Required if shipping the Mac app |

Shot list:

1. This Week day-card stack with tonight on top
2. Fill my week draft with reason chips
3. Family reactions after dinner
4. Ideas inbox with kids' requests
5. Shopping list in store mode
6. Allergy flag with Make it safe
7. Privacy: no ads, no tracking, AI on device

Captions use the tagline voice.

## App Review notes (draft)

Foon uses Sign in with Apple only, so the reviewer signs in with their own Apple ID and creates a household in onboarding (about 2 minutes). To see a populated app instantly, tap "Load a sample family" on the first onboarding screen, which creates demo members, meals, and a planned week. The sample family skips setup, so to see "What Foon does for you" (the recipe and tonight-rescue demo, #236), create a household the normal way instead and tap a few dishes.

Key flows: This Week tab, Fill my week, approve, then the cart icon for the shopping list. Calendar access is optional and off by default: Family, Spot busy evenings asks for it, and This Week then suggests marking busy evenings rushed. AI features use Apple's on-device Foundation Models and appear only on eligible devices; every feature has a non-AI path. The subscription starts with a 30-day free trial; sandbox purchase works from Family, Subscription. Account deletion: Family, Your data, Delete my account (also on the first screen before a household exists). It confirms with Sign in with Apple and revokes the token.

## Compliance checklist

- [ ] Export compliance: standard HTTPS only; set ITSAppUsesNonExemptEncryption to NO
- [x] Privacy manifest (#67): `PrivacyInfo.xcprivacy` in the app (`Foon/App`), the share extension, the after-dinner card and the widget, picked up as resources from each target's folder in `project.yml`. No tracking, no tracking domains. Required-reason APIs: the app declares UserDefaults (CA92.1 for its own settings, 1C8F.1 for the App Group suite) and file timestamps (C617.1, the share inbox clearing stale files in the App Group container); the share extension declares file timestamps (C617.1, the same inbox code); the card and the widget use none. The app's collected data types match the label above except analytics and crash data, which aren't built yet (#28): add them to the manifest when they are. Check the generated privacy report (Xcode Organizer → Generate Privacy Report) on the first archive.
- [ ] In-app account deletion with Sign in with Apple token revocation
- [x] Share extension: App IDs `com.andrikanich.foon` and `com.andrikanich.foon.share` both have App Groups on, with `group.com.andrikanich.foon`
- [x] After-dinner card (#122): App ID `com.andrikanich.foon.dinner` registered with App Groups on, with `group.com.andrikanich.foon`
- [x] Tonight widget (#62): App ID `com.andrikanich.foon.widget` registered with App Groups on, with `group.com.andrikanich.foon`
- [x] Calendar awareness (#64): `NSCalendarsFullAccessUsageDescription` in Info.plist (via project.yml), the Mac's calendars entitlement, and no App Privacy data type (never leaves the device)
- [x] AI queue (#58): background fetch (`UIBackgroundModes: fetch`, already on for #122) with a second refresh identifier, `com.andrikanich.foon.ai`, in `BGTaskSchedulerPermittedIdentifiers` (via project.yml). Only a device that can run Apple's on-device model asks for it; the Mac claims jobs when Foon opens. No new permission prompt. #59's recipe kind is in the label's "Other user content" row and in What Foon keeps
- [x] Dinner memories (#65, part 3): `NSPhotoLibraryUsageDescription` in Info.plist (via project.yml), the Mac's photos entitlement, and no new App Privacy type (library photos never leave the device)
- [x] Receipt scanning (#61): `NSCameraUsageDescription` in Info.plist (via project.yml), iPhone and iPad only (the Mac picks a photo, so no camera entitlement), and no App Privacy type for the photo (never leaves the device)
- [ ] Privacy policy and terms live at the URLs above
- [ ] Sign in with Apple private email relay: sending domain registered
- [ ] Content rights: imported recipes are user-provided and private to the household
- [ ] Paywall shows required subscription terms
- [ ] Sample-family demo mode built for reviewers
- [ ] Enrolled in App Store Small Business Program
