# Compliance self-check (#67)

**DRAFT — pending legal review. Not yet in effect.**

**Self-check, not legal advice.** Checked 2026-11-06. It's meant to make a lawyer's or a COPPA Safe Harbor program's
review shorter, not to replace it.

**How sources were checked.** Three research passes read the primary sources where they could:

- COPPA: the Federal Register final rule (2025-04-22, document 2025-05904) and the FTC's Safe Harbor page.
- State laws: Washington's RCW text on app.leg.wa.gov, Nevada's NRS 603A on leg.state.nv.us, and Texas SB 2420 (enrolled
  text) and Bus. & Com. Code 541.002.
- Apple: the App Review Guidelines and Apple's own developer pages.

Some sources couldn't be read directly:

- eCFR redirected, so the current text of 16 CFR 312.2, 312.4(c)(1), 312.5 and 312.6 wasn't read word for word at
  first. For #275 (2026-11-08), 312.4(c)(1) and 312.5(b)(2)(viii) were read on Cornell LII's copy of the current
  16 CFR; 312.2's "disclose" still rests on the earlier passes.
- Connecticut's site (cga.ct.gov) failed its certificate check.
- The California and Louisiana code pages refused the request.
- Some fetches came back as summaries, not verbatim text.

Where a point rests on a secondary source (a law firm or tracker) or couldn't be confirmed, it says **UNVERIFIED**.
Where the passes disagreed, this file takes the stricter verdict and says so.

Verdicts: **met**, **partly**, **gap**, **n/a** (doesn't apply, with why).

## Before launch

### (a) Wording fixed in this PR

- privacy.md:
  - a "Children under 13" section: what a kid's account generates, why, and who receives it;
  - parents' rights to review, delete and refuse further collection, in plain words;
  - Foon doesn't disclose a child's information except to service providers;
  - providers are bound to protect data at least as strongly as this policy;
  - requests are answered in 45 days, with one 45-day extension, free twice a year, with an appeal route;
  - the postal address in Contact (an `[ADDRESS]` placeholder until #284 filled it in);
  - a link to the consumer health data policy;
  - the retention policy is stated to be part of the notice.
- retention.md:
  - the business need for each kind of kid data;
  - a note that storing Apple's age range under #88 conflicts with Texas 121.055(b).
- consumer-health-data.md: a new draft of the separate Consumer Health Data Privacy Policy (Washington, plus Nevada's
  extra items).
- README.md: the new files, reviewer checklist items, new known gaps, and Safe Harbor programs as a review option.
- app-store-submission.md:
  - "never leaves your phone for AI" becomes "AI runs on your family's own devices";
  - "kids" is dropped from the keywords.
- spec.md: the positioning line gets the same rewording.

### (b) Needs code (not built here)

- **Verifiable parental consent.** Done in #275 (decision 1 below): "email plus", 312.5(b)(2)(viii). The
  `parental-consent` Edge Function emails the direct notice to the asking parent's sign-in address, the parent agrees
  on getfoon.com, and a confirming email with a withdraw link goes out; only then is the consent written
  (`method = 'email_plus'`, `parental-invite-v3`). The app can no longer write a parental consent itself. Part A is
  the server; the site pages (B) and the app (C) follow. Consents given in the app before it no longer count since
  #277 put v3 in force: those kids are held until a parent completes email plus.
- **Direct notice to the parent.** Done in #276: the kid-invite consent screen links the policies, says no invite goes
  out without a yes, and the wording is `parental-invite-v2`.
- **New consent for material changes.** Done in #277: every agreement is logged per person with its wording
  (`agreement_versions`), and a wording change in force asks again. A kid whose consent is outdated is signed out
  (profile kept, no erase clock) while every parent with a verified email gets a renewal notice and one reminder; a
  household whose allergy agreement is outdated can't add allergies; adults see the Terms and Privacy prompt. In force
  since `20261119000000_agreements_in_force.sql`.
- **Delete everything about a child, now.** Done in #278: any parent, on the kid's profile, deletes the kid's data and
  their sign-in account at once (`delete_kid`, job K in retention.md). It answers 312.6 and the unlinked-account gap;
  withdrawing and removing still wait 30 days and 12 months.
- **Allergy consent wording, `allergy-data-v2`.** Done in #280: the sentence names who receives allergies (the
  household, our hosting provider) and how to withdraw (Family → Allergy alerts). Allergies are never in a
  notification's text, so Apple isn't a recipient. The kid-invite consent names the hosting provider and Apple for
  notifications since #276. Households that agreed to v1 are asked again since #277 (Decided by Chris, below).
- **Links to the policies:**
  - the privacy policy on the getfoon.com homepage, onboarding and Family → Your data (the paywall, kid invite and
    join screens have them, #282 and #276);
  - the consumer health data policy on the homepage, the App Store page and in the app.
- **Paywall terms.** Done in #282: restore purchases, the offer row with the price after the trial, the renewal terms
  and Terms of Use and Privacy Policy links (`SubscriptionSection.swift`).
- **Age assurance (#88).**
  - Texas 121.054 needs a system to check each user's age category and a minor's consent status.
  - California AB 1043 (2027-01-01), Louisiana (2027-07-01) and Utah (2027-05-06) follow.
  - Apple's Declared Age Range API: build against the 26.2 SDK or later and handle `confirmed`.
- **Texas store-data deletion.** If #88 stores Apple's age range, delete it once verification is done, keeping at most
  what the law allows. 121.055(b). Done: only kid or adult is kept (decision 6).
- **Texas significant-change notice.** Tell the App Store before a significant change to the terms or privacy policy,
  for example through PermissionKit's Significant Change API. 121.053.
- **CAN-SPAM footer.** Done in #284: every waitlist email ends with the sender, the postal address and the unsubscribe
  link (`emailFooter` in `supabase/functions/waitlist/email.ts`).
- **Delete screen.** Say billing continues through Apple and how to cancel (`DeleteAccountView.swift` has no billing
  line).
- **Waitlist confirmation email.** Done in #284: the founding-family pitch stays, and the email is treated as
  commercial (postal address and unsubscribe in the footer, one-click `List-Unsubscribe`).

### (c) Decisions for Chris or counsel

1. **Consent method.** Decided: email plus (Chris, 2026-11-08; below), built in #275. Its condition is decision 2.
   [CHECK] for counsel: if household visibility is "disclosure", email plus isn't available. Is the fallback then a
   method on the 312.5(b)(2) list that doesn't carry that condition, or a Safe Harbor program's approval of another
   method under 312.5(b)(3)?
2. **Household visibility.** Do household members seeing a kid's name, comments, or anyone's allergies count as
   "disclosure" (COPPA 312.2) or "sharing" with a third party (Washington .010(27))? If yes:
   - email plus is off the table;
   - allergies need separate sharing consent.
3. **Whose consent.** Under Washington's law, who is the "consumer" and who consents for a child? Allergy consent is
   one household-wide agreement by a parent, and only parents can withdraw it for the household: is that enough for
   another adult's allergies? Adults can now add and remove their own in the app (#285), adding under the parent's
   agreement without giving their own, and a parent can add them again.
4. **The state health-data laws.** Comply with Washington, Nevada and Connecticut, or block those states? This file
   recommends complying to Washington's standard.
5. **Connecticut SB 1295.** Does it reach Foon with no volume floor (sensitive data)? This rests on secondary sources
   only.
6. **Texas age range.** Decided (Chris, 2026-11-11; below), built in #88: only a derived kid/adult flag is kept.
7. **Contact details.** The postal address is decided (#284): 34125 Center Ridge Road #1012, North Ridgeville, OH
   44039, in the privacy policy, the consumer health data policy, the terms, the website's privacy page and the
   waitlist email footer. Still open: a phone number? 312.4(d)(1) lists one.
8. **Security program.** Who is named in the written information security program (312.8(b)), and who signs the
   yearly review?
9. **Processor agreements.** Sign and file DPAs with Supabase, Resend and Vercel. For Supabase, Washington .060 and
   Nevada 603A.530 make a contract a legal duty.
10. **Rights requests.** Who answers them and where (support@getfoon.com, or an in-app form)? An appeal mailbox, and
    the Washington AG's complaint link.
11. **Age rating.** Re-answer Apple's 2026 questionnaire (medical/wellness, user-generated content). Set a higher
    rating to match "18+ account holders"?
12. **EULA.** Apple's standard EULA with our Terms linked, or our own EULA with Apple's minimum clauses?
13. **Trial length.** "30 days" or "one month"? The listing, spec, terms and paywall must agree.
14. **Allergy "Other" free text.** Could someone type a medication or diagnosis? If so, say so in the categories.
15. **New York.** Recheck S9269 (NY Health Information Privacy Act) before launch.
16. **Research not done:** Vermont's and Nebraska's age-appropriate design codes, and the Texas SCOPE Act.
17. **Forwarded receipts (#237).** Built and shipped without a flag (Chris, 2026-11-12). Purchase lines from a
    forwarded store email now reach Foon's servers (kept until reviewed, 14 days at most), and Resend keeps the whole
    email for 30 days with no way to delete it sooner. Only adults can add a forwarding address, and only from an
    address they confirm. The privacy draft describes it under Forwarded receipts, but `privacy-draft-v2`, the version
    in force, doesn't. Is this a significant change that needs `privacy-draft-v3` and a new agreement before families
    use it? Is Resend's 30 days acceptable, or should receiving move to a provider that deletes on delivery?

**Decided by Chris (2026-11-11), for counsel to confirm in their review (#88):**
- **Texas age range (decision 6, §121.055(b)).** After a claim Foon keeps only whether Apple's age range said adult or
  a minor (`members.declared_adult`: true, false, or null when Apple didn't say), never the band itself. `redeem_invite`
  uses the band to refuse a mismatch (`age_mismatch`) and then drops it; bands kept before this were turned into the
  flag and deleted. The flag's one use: Delete everything about a kid only unlinks, never deletes, an account whose
  claim said adult.

**Decided by Chris (2026-11-08), for counsel to confirm in their review (#275):**
- **Consent method: email plus** (312.5(b)(2)(viii)). Email 1 is the direct notice, to the address on the asking
  parent's own Sign in with Apple account; the parent agrees on getfoon.com; email 2 confirms it and says how to
  withdraw. Consent is active once email 2 has gone out, with no second click: the rule asks for a confirmatory
  email after consent, not a reply to it.
- **No email on the account.** The parent may type one. It's kept only on the request and cleared once email 2 is
  sent or the request ends (312.5(c)(1) lets an operator collect a parent's online contact for consent).
- **Link lifetimes.** The consent link works 7 days; the withdraw link 30 days. Withdrawing in the app always works.
- **No carry-over.** Consents given in the app before #275 were never a listed method. They're tagged `in_app`,
  nothing is revoked, and since #277's turn-on those kids are held until a parent completes email plus.
- **Sender and language.** From info@getfoon.com (`CONSENT_FROM`), in English only.

**Decided by Chris (2026-11-07), for counsel to confirm in their review:**
- **Allergy consent already given (#280).** ~~Consent is asked once: households that agreed to `allergy-data-v1`
  aren't asked again.~~ Reversed by Chris on 2026-11-09 (#277: over-cover, over-log, over-communicate): households
  that agreed to v1, which named neither recipients nor withdrawal, are asked again. Their allergies keep flagging and
  removing still works, but nobody adds one until a parent agrees to `allergy-data-v2`. Every new agreement uses v2.
- **What a parent's export leaves out (#279).** A kid's sign-in details and push token stay out of the export, and
  support provides them on request. That's enough friction to stop casual requests, and still meets 312.6(a)(3).
- **Re-adding allergies an adult removed (decision 3).** A parent can add them again, and Foon won't block it.
- **A kid's profile switched to adult.** A parent who isn't a planner loses the reminder log and hidden comments from
  when the profile was a kid's, since a parent reads those only while it's marked a kid (planners still see hidden
  comments). That stays as is.

## COPPA (16 CFR 312, as amended; compliance date 2026-04-22)

Foon knowingly has under-13 users: a parent marks a profile as a kid and invites them. So COPPA applies whatever Foon's
size.

| Requirement | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Online notice linked on the home page and where kids' information is collected | 312.4(d) | Linked on the paywall, the kid invite and join screens, onboarding's agreement screen, Your data and the site footer on every page, homepage included (#282, #276, #277, #281) | met | |
| Operator name, address, phone, email | 312.4(d)(1) | privacy.md Contact: LLC, postal address (#284), email; no phone | partly | Phone: decision 7 (whether email-only is accepted is UNVERIFIED) |
| What's collected from kids, how it's used, who gets it | 312.4(d)(2) | privacy.md "Children under 13" (this PR), Kids, tables | partly → met in this PR | Wording (this PR) |
| Retention policy in the notice | 312.4(d)(2), 312.10 | privacy.md How long we keep it; retention.md Kids | partly | Wording (this PR): retention.md stated to be part of the notice, with business need. The passes disagreed: one said met; this file takes partly |
| Internal-operations identifiers (account ID, push token, provider logs) | 312.4(d)(3) | privacy.md Your account, Reminders; provider logs `[CHECK]` | partly | Wording after confirming Supabase and Vercel logs |
| Parent's right to review, delete, refuse further collection, stated | 312.4(d), 312.6 | privacy.md Kids (this PR states all three) | partly → met in this PR | Wording (this PR) |
| Direct notice to the parent before consent | 312.4(b), (c)(1) (read on LII, #275) | Email 1 (`noticeEmail` in `supabase/functions/parental-consent/email.ts`, `parental-invite-v3`): (i) why the parent gets it and that nothing was collected from the kid, (ii) consent is needed and what happens without it, (iii) what's collected and how it's used, (iv) no disclosure beyond the services that run Foon, (v) the privacy policy link, (vi) how to consent, (vii) the 7-day lapse; plus how to withdraw, the operator and contact. Unit-tested element by element | met pending counsel | Counsel to confirm the wording |
| New consent for material changes | 312.4(b), 312.5(a)(1) | Wording versions and holds (#277): an outdated kid consent signs the kid out until a parent renews by email plus (renewal notice, one reminder) | met in code | Counsel to confirm the renewal notice |
| Verifiable parental consent before collection | 312.5(a)(1), (b)(1) | Email plus (#275): a kid can't be invited or claim a profile until a parent agreed from email 1 and email 2 went out; the record keeps the method, both times and the wording. Consents from before #275 are `in_app` and stay until #277 | met pending counsel | Decision 2; #277 for the earlier consents |
| Accepted method in the safe list | 312.5(b)(2)(i)-(ix) | Email plus, 312.5(b)(2)(viii): confirmatory email after consent, with the notice that the parent can revoke (#275) | met pending counsel | Decision 2 |
| Email plus / text plus only for operators that don't disclose | 312.5(b)(2)(viii)-(ix); "disclose" in 312.2 (UNVERIFIED) | Processors are service providers, not disclosure | open | Decision 2 |
| Separate consent for third-party disclosure | 312.5(a)(2) | No disclosure to third parties for their own use | n/a | Wording (this PR): said plainly. Analytics (#28) would need it |
| Parent can review a kid's information | 312.6(a)(1), (a)(3) | Visible in the household; every parent reads a kid's reminder log and hidden comments, and exports (#279) | met | None |
| Parent can refuse further collection and delete | 312.6(a)(2) | Withdraw unlinks at once; Delete everything about a kid deletes their data and sign-in account at once (#278) | met | Counsel: deleting the consent record with it |
| Written retention policy: purpose, business need, deletion timeframe; nothing kept indefinitely | 312.10 | retention.md Kids (business need added in this PR) | partly | Remaining: the kid's sign-in account (known gaps). Counsel: "while the household exists" for an active household's kid ratings and the consent record may read as indefinite |
| Written information security program: named person, yearly risk assessment, safeguards, testing, yearly review | 312.8(b)(1)-(5) | Nothing written; privacy.md Security lists safeguards | gap | A document (decision 8) |
| Assurances from service providers | 312.8(c) | DPAs not on file | gap | Paperwork (decision 9) |
| Directed to children / mixed audience | 312.2 | A general-audience household app with parent-invited kid accounts; every kid account treated as covered | met (position) | Don't call Foon "mixed audience" |

FTC-approved COPPA Safe Harbor programs (from the FTC's page): CARU, ESRB, iKeepSafe, kidSAFE, PRIVO and TRUSTe.

## Washington My Health My Data Act (RCW 19.373)

Allergies are consumer health data ("individual health conditions", .010(8)(b)(i)). The act has no size threshold; a
small business only got later dates, now passed (.010(28)). It covers a business that targets Washington consumers
(.010(23)). Selling on the US App Store qualifies; that's the research pass's conclusion, not the statute's words. A
violation is a Consumer Protection Act violation (.090). The AG's FAQ says people can sue.

| Requirement | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Separate consumer health data privacy policy | .020(1)(a); AG FAQ 4 (paraphrased, partly verified) | consumer-health-data.md (this PR, draft) | gap → draft | Publish after review |
| Linked prominently from the homepage (for an app: its download page and in-app) | .020(1)(b), .010(16) | Not linked | gap | Code: site footer, App Store page, Family → Your data |
| Categories, purpose, use; sources; categories shared; third parties and affiliates; how to use rights | .020(1)(a)(i)-(v) | consumer-health-data.md | met in draft | — |
| No new categories or purposes without disclosure and consent | .020(1)(c)-(d) | Spec and policy limit use to flagging | met | Keep as an engineering rule |
| Processor contract consistent with the policy | .060, .020(1)(e) | DPA not confirmed | partly | Decision 9 |
| Consent before collecting | .030(1) | Agree and save, `allergy-data-v2` (#280; v1 agreements stand, Decided by Chris); server refuses without it. One household-wide agreement by a parent covers every adult's allergies | partly | Decision 3 |
| Consent request names categories, purpose, recipients, how to withdraw | .030(2) | `allergy-data-v2` (#280) names the household and hosting provider and Family → Allergy alerts; v1 agreements, which named neither, aren't asked again | met for new consent | Decided by Chris: counsel to confirm v1 can stand |
| Separate consent to share | .030(1)(b) | Nothing shared outside processors | n/a | Unless household visibility is "sharing" (decision 2) |
| Access, including third parties and their contacts | .040(1)(a) | Visible in the household; planners and parents export (#279) | partly | Policy says no third parties; access request by email |
| Withdraw consent | .040(1)(b) | Allergy alerts off erases all (a parent); any adult removes their own on their profile, one at a time or all at once (#285), though a parent can add them again | partly | Decision 3 |
| Delete, including backups (up to 6 months) | .040(1)(c) | At once; backups 7 days | met | — |
| 45 days, one 45-day extension; free twice a year; no new account needed | .040(1)(d), (f), (g) | Was "the time the law allows" | gap → fixed | Wording (this PR) |
| Appeal: written answer in 45 days, AG contact if denied | .040(1)(h) | None | gap → fixed | Wording (this PR); AG link `[CHECK]` |
| Security and need-to-know access | .050 (text UNVERIFIED) | RLS by household | partly | Name it in the security program |
| No sale without authorization; no geofencing | .070, .080 | Never sold; no location | n/a | — |

## Nevada SB 370 (NRS 603A.400–.550)

No size threshold or small-business exemption (603A.490 exempts HIPAA, GLBA and similar only). There's no private
right of action (603A.550). The definition's exact wording is UNVERIFIED (603A.430). One reading calls it use-based;
Foon's use, flagging a known allergy, would still count.

| Requirement | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Maintain and conspicuously link a policy | 603A.495 | consumer-health-data.md (this PR) | gap → draft | Code: links, as for Washington |
| Extra contents: processing methods, request procedure, review and correction, material changes, cross-site collection, effective date | 603A.495 (paraphrased; read the section directly) | consumer-health-data.md Nevada section | met in draft | Confirm the list against 603A.495 |
| Consent to collect, separate consent to share, disclosures in the request | 603A.500 | As Washington: `allergy-data-v2` (#280) | met for new consent | Decided by Chris: v1 stands |
| Confirm, third-party list, stop collecting, delete; 45 days + 45 | 603A.505 | Wording (this PR) | met in draft | — |
| Delete within 30 days of an authenticated request; processors too; backups ≤ 2 years | 603A.515 | In-app at once; backups 7 days | met | Draft states 30 days for emailed requests |
| Appeal, 45 days, AG contact | 603A.520 | Wording (this PR) | met in draft | AG contact `[CHECK]` |
| Security, need-to-know | 603A.525 | RLS | partly | Name it in the security program |
| Processor contract | 603A.530 | Not on file | partly | Decision 9 |

## Connecticut (CTDPA health-data provisions, and SB 1295)

Connecticut's statute text couldn't be read (certificate error), so every row here is **UNVERIFIED**, from secondary
sources. One research pass found that from 2026-07-01, SB 1295 (PA 25-113) applies the whole CTDPA to anyone
processing sensitive data, with no volume floor; health data and known children's data count as sensitive. If so,
Foon is covered now. The other pass rated this "possibly yes". This file takes the stricter verdict: treat Foon as
covered and have counsel confirm.

| Requirement | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Consent before processing consumer health data | CTDPA as amended by PA 23-56 | Agree and save | met | — |
| No sale of health data without consent | same | Never sold | met | — |
| Staff and contractors under a confidentiality duty | same | Nothing written | gap | Paperwork |
| Processors under a written contract | same | DPA not confirmed | partly | Decision 9 |
| Privacy notice contents, rights, 45 days, appeal | CTDPA (if SB 1295 applies) | privacy.md Your rights (this PR) | partly | Counsel to confirm the CT list |
| Data protection assessment for sensitive data | CTDPA | None | gap | A document, not code |
| Heightened duties for minors 13–17 | SB 1295 (reported) | Foon doesn't sell | open | Counsel |

## New York Health Information Privacy Act (S9269 / A10357), pending

The 2025 version was vetoed on 2025-12-19. The revised bill passed both houses in 2026. No signature or veto was found
as of mid-July 2026; anything later is **UNVERIFIED**. As drafted it has no size threshold and bans sale. Other
processing needs a separate authorization or a "strictly necessary" purpose, and access and deletion are due within
30 days.

| Requirement | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Whole bill | S9269 | — | n/a until signed | Decision 15 |

## Apple App Review Guidelines

| Requirement | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Privacy policy linked in App Store Connect and in the app | 5.1.1(i) | Stub URL; in-app links not built | gap | Code; publish after review |
| Policy says what's collected, how, and all uses | 5.1.1(i) | privacy.md tables | met | — |
| Third parties give the same or equal protection | 5.1.1(i) | Wording (this PR) | partly → fixed | Plus DPAs (decision 9) |
| Retention, deletion, how to revoke consent | 5.1.1(i) | privacy.md, retention.md | met | — |
| Consent, easy to withdraw | 5.1.1(ii) | Allergy and kid consent, both withdrawable | met | — |
| Data minimization | 5.1.1(iii), (iv) | Optional allergies, calendar, photos | met | Keep the calendar note in review notes |
| In-app account deletion | 5.1.1(v); Apple's account deletion page | Family → Your data → Delete my account | partly | Code: billing line on the delete screen (a kid's self-delete does remove the sign-in row) |
| Say what's kept after deletion | Apple deletion FAQ | privacy.md Deleting | partly | Show "anonymous ratings stay" on the delete screen (code) |
| No sharing without permission, including AI | 5.1.2(i) | On-device AI; #59 queue stays in the family's devices | met | Wording (this PR): marketing line |
| Apps that collect from minors need a policy and must follow children's privacy law, even outside the Kids Category | 5.1.4(b) | Not in Kids Category | partly | See COPPA |
| Outside the Kids Category, don't suggest kids are the main audience | 2.3.8 | Keyword "kids" | partly | Wording (this PR): dropped |
| Subscription screen: name, duration, renewal price, trial, restore, Terms and Privacy links | 3.1.2; Apple's Subscriptions page | Offer row (name, price, trial and the price after it), renewal terms, restore purchases, and Terms and Privacy links (`SubscriptionSection.swift`, #282) | met | Decision 13 (trial wording) |
| EULA | 3.1.2 (wording UNVERIFIED) | terms.md layers Apple's EULA | partly | Decision 12 |
| Privacy label accurate | App Privacy Details | Label rows in app-store-submission.md | partly | Check whether the push token is "Device ID" and whether kept request logs (IPs) count (both UNVERIFIED); the age range row is in (#88) |

## Apple age ratings and Declared Age Range (2026)

| Requirement | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Answer the new age-rating questions (4+/9+/13+/16+/18+); updates were blocked after 2026-01-31 | Apple news 2025-07-24 | Not re-answered against the new questions | partly | Decision 11 |
| Answer honestly | 2.3.6 | — | partly | Same |
| Declared Age Range API, iOS/macOS 26+; `confirmed` from iOS 26.5 | Apple Age Assurance page | Join family asks once and sends only the band to `redeem_invite` (#88); `confirmed` is a declaration type, and Foon reads only the range | partly | Sandbox device test (docs/parental-consent.md) |
| Developers handle their own age limits | Apple Age Assurance page | Terms say 18+; the band is checked only when someone claims a profile (`age_mismatch`, #88), not at sign-up | partly | Decision |
| Significant Change and `RESCIND_CONSENT` notifications where required | Apple Age Assurance page | Significant-change hook built (#88, iOS 26.4+, where `requiredRegulatoryFeatures` says so); no change qualifies yet. `RESCIND_CONSENT` waits for the App Store Server Notifications endpoint | partly | Code (Phase 4) |

## App-store age laws

Status as of 2026-11-06:

- **Texas SB 2420.** In force. The Fifth Circuit stayed the injunction (2026-06-04), and the Supreme Court declined to
  vacate the stay (2026-07-06). The merits appeal was argued 2026-08-04, with no decision found (later events
  **UNVERIFIED**).
- **Utah, Louisiana and California.** Later dates, from secondary sources (**UNVERIFIED**).

| Requirement on a developer | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Texas: rate the app and each purchase, and tell the store | SB 2420 §121.052 | Questionnaire not re-answered | partly | Decision 11 |
| Texas: tell the store before a significant change to terms or privacy policy | §121.053 | Significant-change hook (#88): add the change to `SignificantChange.all` and a minor's parent approves through PermissionKit, an adult acknowledges | partly | Process: decide which changes qualify |
| Texas: verify each user's age category and a minor's consent | §121.054 | Age band asked at claim (#88), parental consent by email plus (#275); not at sign-up | partly | Decision; good-faith reliance on the store's data is a safe harbor (§121.056(c)) |
| Texas: use store data only for listed purposes, and delete it after verification | §121.055(a)-(b) | The band is used only to refuse a mismatched claim, then dropped; only kid or adult is kept (#88, decision 6) | partly | The parental consent wording (`parental-invite-v3`: both consent emails and the /consent page) still lists "an age range from Apple" as kept; fix with the next wording change. Counsel to confirm a derived kid/adult flag may be kept |
| Utah (HB 498): developer duties from 2027-05-06 | UNVERIFIED | Not built | gap (later) | Code (#88) |
| Louisiana (HB 977): use store age signals from 2027-07-01 | UNVERIFIED | Not built | gap (later) | Code (#88) |
| California AB 1043: ask for an age signal at download and launch, from 2027-01-01; it counts as actual knowledge | UNVERIFIED | Not built | gap (later) | Code (#88) |

## General US state privacy laws

| Law | Threshold | Does Foon cross it? | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Ohio | No comprehensive consumer privacy law (UNVERIFIED; the legislature's site wasn't checked) | — | n/a | — |
| California CCPA/CPRA | Over $25M revenue, 100,000 consumers, or 50% of revenue from selling data | No | n/a | No California notice needed until a threshold is crossed |
| Virginia, Colorado, Oregon and similar | Typically 100,000 consumers, or 25,000 plus sale revenue (UNVERIFIED per statute) | No | n/a | Watch user counts |
| Maryland MODPA | 35,000, or 10,000 plus 20% sale revenue (UNVERIFIED) | No | n/a | Monitor |
| Texas TDPSA | Excludes SBA small businesses except §541.107 (sale of sensitive data needs consent; 541.107 text not read) | Small (NAICS standard UNVERIFIED) | met | Foon never sells; keep saying so |
| Nebraska | No volume threshold; small businesses exempt except sale of sensitive data (UNVERIFIED) | — | met | As Texas |
| Connecticut | See above | Probably | gap | See above |

## Kids' codes

| Law | Applies to Foon? | Verdict | Fix |
| --- | --- | --- | --- |
| Maryland Kids Code | In effect, not enjoined. Covers $25M+ revenue, or 50,000+ consumers' data bought, sold or shared, or half of revenue from selling data. Foon meets none (statute text UNVERIFIED) | n/a | — |
| California AADC | Partly enjoined (Ninth Circuit, 2026-03-12). Covers CCPA businesses only | n/a | — |
| Vermont and Nebraska age-appropriate design codes, Texas SCOPE Act | Not researched | open | Decision 16 |
| FTC Act §5 and state deceptive-practice laws | Yes: "no ads, no tracking, never sold" are enforceable promises | met | Keep them true when #28 ships |

## CAN-SPAM (waitlist emails)

The parental consent emails (#275) are transactional: they carry no offer and go only to a parent who asked. They
still name the sender and postal address.

| Requirement | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Accurate headers | FTC guide 1 | `WAITLIST_FROM` on a Resend-verified domain | met | Confirm the production value |
| Honest subject | FTC guide 2 | "Confirm your spot on the Foon waitlist" | met | — |
| Identified as an ad, unless the recipient opted in | FTC guide 3 | Opt-in; the confirmation carries an offer and is treated as commercial (#284) | partly | Counsel: whether a signer who asked to join counts as "opted in" before confirming (UNVERIFIED) |
| Valid postal address | FTC guide 4 | Every waitlist email's footer and the privacy policy's Contact (#284) | met | — |
| Clear opt-out, honored in 10 business days, working 30+ days | FTC guide 5, 7 | Unsubscribe link, one-click `List-Unsubscribe`, deletes at once, link doesn't expire | met | Optional: keep a suppression hash |
| Transactional only if confirming is the main purpose | 16 CFR 316.3 (UNVERIFIED) | The pitch stays; the confirmation is treated as commercial, with the address and unsubscribe (#284) | met | — |
| Responsible for mail sent on your behalf | FTC guide 8 | Resend | met | — |
