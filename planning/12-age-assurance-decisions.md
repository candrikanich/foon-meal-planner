# #12 Age assurance and parental consent — decisions

Status: **decided 2026-10-26**: 1A (parent consents at invite), 2A (age range once, at claim), retention as proposed, legal review before external TestFlight. Built in two parts: #12 (server rules, consent at invite, retention) and #88 (Declared Age Range, revocation at launch, significant-change hook). Researched 2026-10-26. This isn't legal advice: the spec already requires a legal review before launch, and these choices should go to it.

## Where things stand (Oct 2026)
- **Texas (SB 2420).** In force for new Texas Apple Accounts since June 4, 2026: the Fifth Circuit stayed the December 2025 injunction, but the stay isn't final. Developers must:
  - read the account's **age category** (under 13, 13–15, 16–17, or 18+) with Apple's **Declared Age Range API**;
  - ask a parent again through **PermissionKit's Significant Change API** when the app changes significantly (an age-rating change counts);
  - handle **consent revocation**, reported by App Store server notifications.
- **COPPA (amended rule, compliance since April 22, 2026).** Collecting personal information *from* a child under 13 needs verifiable parental consent. Operators also need a **written data-retention policy with a time period** (in the privacy notice) and a **written information security program**.
- **What Foon collects from kids** who use their own device: first name and avatar (entered by a parent), ratings, requests, comments, and list taps. Allergies are entered only by guardians.

## What's already built
- Kids are profiles a **parent creates** (adult or kid, set by guardians). A kid can't make themselves an adult.
- `consents(kind = 'parental', member_id = <kid>)` exists. Only guardians can record it, and only for a kid's profile. Revoking is logged, never deleted.
- Kids join only through an **invite a parent sends**: single-use, expiring, revoked when the profile is removed.
- Minimal data: no birthdates, photos of people or location; allergies stay household-only and on the device for AI.

## Decisions needed

### 1. Can kids under 13 use Foon on their own device in v1?
- **A. Yes, with parental consent recorded when the parent invites them (recommended).** Inviting a kid's profile includes a consent step ("I'm Owen's parent and allow him to use Foon"), logged in `consents`. `redeem_invite` refuses kid profiles without it. Apple's age range check (decision 2) confirms the device's account. *Needs legal review on whether this counts as "verifiable" consent under COPPA; the FTC's listed methods don't name in-app attestation by an already-signed-in parent.*
- **B. Not in v1.** Under-13s take part only through "pass the phone" on a parent's device; kid profiles 13 and up may be invited. This is the safest COPPA position until the legal review, but it gives up a core part of the product (kids rating and requesting on their own phones).
- **C. Use Apple's parental approval as the consent.** For a child account in Family Sharing, ask the parent to approve through PermissionKit's `RequestParentalApprovalView`. Stronger evidence than A, but the docs and developer forum are unclear on whether PermissionKit works outside Messages. Worth a spike before committing.

### 2. When does Foon ask for the age range?
- **A. Once, when someone claims a profile (recommended).** One system prompt. Foon stores only the band (`under13 | 13-15 | 16-17 | adult | unknown`), never a birthdate. Profiles must match the account: a minor's account can't claim an adult profile, and claiming a kid profile follows decision 1.
- **B. At every sign-in.** More checks, more prompts, little gain.
- **C. Only in Texas.** The API covers this, but one path everywhere is simpler and future-proof (Utah, Louisiana and others have similar laws).

### 3. Revocation and significant changes
- **Recommended:** build the client side now.
  - Check the age range and consent status at launch; if revoked, the kid's account loses access, as with removal (the profile and its history stay).
  - Add a `significantChange()` hook that asks parents again, but trigger it only when something qualifies, such as an age-rating change.
- The **App Store server notification** endpoint (an Edge Function) waits for the StoreKit work in Phase 4, which sets up App Store Server Notifications anyway.

### 4. Data-retention policy (COPPA requires a time period)
Proposed policy, to put in the privacy notice:
- **Deleting the household erases everything at once** (this is already planned).
- **A removed kid's profile is anonymized after 12 months:** first name replaced with "Former member", avatar cleared, allergies deleted. Ratings stay as anonymous history, so planning still learns from them.
- **Revoked parental consent:** the kid's account is unlinked at once. After 30 days without new consent, what the kid added themselves and their age band are erased; the parent-entered profile (name, avatar, allergies) stays while they're in the family (Chris, 2026-10-26, after review flagged that anonymizing an active kid would delete their allergy flags).
- **Receipt images are deleted after parsing** (already in the spec).

### 5. When does the legal review happen?
- **Recommended:** before **external** TestFlight (the founding families), not just before launch. Internal TestFlight with your own family can go ahead under decision 1A or 1B.

## What I'll build once you decide
- A consent step in the invite sheet for kid profiles; a `redeem_invite` check; age-band capture at claim; launch-time revocation handling; a `significantChange()` hook; and an anonymization job (a scheduled Edge Function or `pg_cron`) for the retention policy.
- Plus spec updates and tests: pgTAP for redeem refusals and anonymization, Swift for the flows.

## Sources
- [Apple: Next steps for apps distributed in Texas](https://developer.apple.com/news/?id=2ezb6jhj)
- [Apple: New requirements for apps available in Texas](https://developer.apple.com/news/?id=btkirlj8)
- [Apple: Implementing age assurance and permissions](https://developer.apple.com/documentation/declaredagerange/implementing-age-assurance-and-permissions)
- [AppleInsider: Age verification now mandatory for App Store users in Texas (June 3, 2026)](https://appleinsider.com/articles/26/06/03/age-verification-now-mandatory-for-app-store-users-in-texas)
- [Apple Developer Forums: PermissionKit outside Messages](https://developer.apple.com/forums/thread/806978)
- [Toy Association: Updated COPPA rule requirements take effect April 22](https://toyassociation.org/PressRoom2/News/2026-News/updated-coppa-rule-requirements-take-effect-april-22.aspx)
- [Mondaq: Enforcement begins soon for significant COPPA rule amendments](https://mondaq.com/unitedstates/privacy-protection/1771468/enforcement-begins-soon-for-significant-coppa-rule-amendments)
- [Kirkland: FTC publishes COPPA rule](https://www.kirkland.com/publications/kirkland-alert/2025/04/ftc-publishes-coppa-rule)
