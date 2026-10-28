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
| Support URL | TBD (landing page /support) | |
| Marketing URL | TBD (landing page) | |
| Privacy policy URL | TBD (landing page /privacy) | Required |

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
| Other user content (meals, comments, requests) | Yes | App functionality | Yes |
| User ID | Yes | App functionality | Yes |
| Purchase history | Yes | App functionality | Yes |
| Product interaction | Yes | Analytics | No (anonymized) |
| Crash and performance data | Yes | App functionality | No (scrubbed) |

Not collected: precise or coarse location, contacts, browsing history, search history, financial info, sensitive info beyond allergies, calendar data (read on device only, never collected).

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

Foon uses Sign in with Apple only, so the reviewer signs in with their own Apple ID and creates a household in onboarding (about 2 minutes). To see a populated app instantly, tap "Load a sample family" on the first onboarding screen, which creates demo members, meals, and a planned week.

Key flows: This Week tab, Fill my week, approve, then the cart icon for the shopping list. AI features use Apple's on-device Foundation Models and appear only on eligible devices; every feature has a non-AI path. The subscription starts with a 30-day free trial; sandbox purchase works from Family, Subscription. Account deletion: Family, Your data, Delete my account (also on the first screen before a household exists). It confirms with Sign in with Apple and revokes the token.

## Compliance checklist

- [ ] Export compliance: standard HTTPS only; set ITSAppUsesNonExemptEncryption to NO
- [ ] Privacy manifest (required-reason APIs declared)
- [ ] In-app account deletion with Sign in with Apple token revocation
- [ ] Privacy policy and terms live at the URLs above
- [ ] Sign in with Apple private email relay: sending domain registered
- [ ] Content rights: imported recipes are user-provided and private to the household
- [ ] Paywall shows required subscription terms
- [ ] Sample-family demo mode built for reviewers
- [ ] Enrolled in App Store Small Business Program
