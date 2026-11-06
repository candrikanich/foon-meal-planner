# Compliance self-check (#67)

**Self-check, not legal advice.** Checked 2026-11-06. It's meant to make a lawyer's or a COPPA Safe Harbor program's
review shorter, not to replace it.

**How sources were checked.** Three research passes read the primary sources where they could:

- COPPA: the Federal Register final rule (2025-04-22, document 2025-05904) and the FTC's Safe Harbor page.
- State laws: Washington's RCW text on app.leg.wa.gov, Nevada's NRS 603A on leg.state.nv.us, and Texas SB 2420 (enrolled
  text) and Bus. & Com. Code 541.002.
- Apple: the App Review Guidelines and Apple's own developer pages.

Some sources couldn't be read directly:

- eCFR redirected, so the current text of 16 CFR 312.2, 312.4(c)(1), 312.5 and 312.6 wasn't read word for word.
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
  - `[ADDRESS]` in Contact;
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

- **Verifiable parental consent.** Today's in-app agreement isn't a method listed in 312.5(b)(2). The cheapest listed
  one is "email plus": a direct notice to the parent's email, consent, then a confirming step. Foon collects no parent
  email or phone today.
- **Direct notice to the parent.** The kid-invite consent screen needs:
  - a privacy-policy link;
  - a line on what happens if the parent doesn't respond;
  - a new consent text version.
- **New consent for material changes.** Store the consent version per kid, and hold a kid's access until a parent
  agrees to the new one.
- **Delete everything about a child, now.**
  - It would remove the kid's data and their sign-in account at once.
  - It answers 312.6 and the unlinked-account gap.
  - The 30-day and 12-month delays don't.
- **Every guardian can review a kid's data.** Planners only get read access to the kid's reminder log and hidden
  comments today, and only planners can export.
- **Allergy consent wording, `allergy-data-v2`.** The sentence must:
  - name who receives allergies (the household, our host provider);
  - say how to withdraw (Family → Allergy alerts).
- **Links to the policies:**
  - the privacy policy on the getfoon.com homepage, the kid invite/join screens, the paywall, onboarding and
    Family → Your data;
  - the consumer health data policy on the homepage, the App Store page and in the app.
- **Paywall terms.** The paywall needs:
  - plan name, duration, full renewal price, and trial length with the price after it;
  - restore purchases;
  - links to the Terms of Use and Privacy Policy.

  Not checked in code.
- **Age assurance (#88).**
  - Texas 121.054 needs a system to check each user's age category and a minor's consent status.
  - California AB 1043 (2027-01-01), Louisiana (2027-07-01) and Utah (2027-05-06) follow.
  - Apple's Declared Age Range API: build against the 26.2 SDK or later and handle `confirmed`.
- **Texas store-data deletion.** If #88 stores Apple's age range, delete it once verification is done, keeping at most
  what the law allows. 121.055(b).
- **Texas significant-change notice.** Tell the App Store before a significant change to the terms or privacy policy,
  for example through PermissionKit's Significant Change API. 121.053.
- **CAN-SPAM footer.** The waitlist email needs a postal address in its footer.
- **Account deletion.** Confirm in code:
  - that a kid's self-delete removes the sign-in row;
  - that the delete flow tells a subscriber billing continues through Apple and how to cancel.
- **Waitlist confirmation email** (`supabase/functions/waitlist/email.ts`): drop the founding-family pitch, or add the
  postal address and treat it as commercial.

### (c) Decisions for Chris or counsel

1. **Consent method.** Use email plus, or text plus, or ask a Safe Harbor program to approve another method under
   312.5(b)(3)?
2. **Household visibility.** Do household members seeing a kid's name, comments, or anyone's allergies count as
   "disclosure" (COPPA 312.2) or "sharing" with a third party (Washington .010(27))? If yes:
   - email plus is off the table;
   - allergies need separate sharing consent.
3. **Kids' allergy data.** Under Washington's law, who is the "consumer" and who consents for a child?
4. **The state health-data laws.** Comply with Washington, Nevada and Connecticut, or block those states? This file
   recommends complying to Washington's standard.
5. **Connecticut SB 1295.** Does it reach Foon with no volume floor (sensitive data)? This rests on secondary sources
   only.
6. **Texas age range.** Keep Apple's age range after verification, or store only a derived kid/adult flag?
7. **Contact details.** A postal address, a registered mailbox or PO box, for the privacy policy, the COPPA notice and
   the CAN-SPAM footer. Also a phone number? 312.4(d)(1) lists one.
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

## COPPA (16 CFR 312, as amended; compliance date 2026-04-22)

Foon knowingly has under-13 users: a parent marks a profile as a kid and invites them. So COPPA applies whatever Foon's
size.

| Requirement | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Online notice linked on the home page and where kids' information is collected | 312.4(d) | Planned for getfoon.com/privacy and the app's paywall, onboarding and Your data; nothing at the kid invite or join screens | partly | Code: links on the homepage and invite/join screens |
| Operator name, address, phone, email | 312.4(d)(1) | privacy.md Contact: LLC, Ohio, email | gap | Wording (this PR): `[ADDRESS]`. Phone: decision 7 (whether email-only is accepted is UNVERIFIED) |
| What's collected from kids, how it's used, who gets it | 312.4(d)(2) | privacy.md "Children under 13" (this PR), Kids, tables | partly → met in this PR | Wording (this PR) |
| Retention policy in the notice | 312.4(d)(2), 312.10 | privacy.md How long we keep it; retention.md Kids | partly | Wording (this PR): retention.md stated to be part of the notice, with business need. The passes disagreed: one said met; this file takes partly |
| Internal-operations identifiers (account ID, push token, provider logs) | 312.4(d)(3) | privacy.md Your account, Reminders; provider logs `[CHECK]` | partly | Wording after confirming Supabase and Vercel logs |
| Parent's right to review, delete, refuse further collection, stated | 312.4(d), 312.6 | privacy.md Kids (this PR states all three) | partly → met in this PR | Wording (this PR) |
| Direct notice to the parent before consent | 312.4(b), (c)(1) (exact text UNVERIFIED) | `ParentalConsent.statement`: names data types, "shared only with this household", no policy link, no line on non-response | partly | Code: link, non-response line, new text version |
| New consent for material changes | 312.4(b), 312.5(a)(1) | privacy.md Changes promises it; no mechanism | gap | Code |
| Verifiable parental consent before collection | 312.5(a)(1), (b)(1) | In-app agreement by a signed-in adult (`parental-invite-v1`); nothing checks it's the parent | gap | Code (email plus), or Safe Harbor approval (312.5(b)(3)). One pass called this UNVERIFIED; this file takes gap |
| Accepted method in the safe list | 312.5(b)(2)(i)-(ix) | Not on the list. Apple subscription isn't a card notice Foon sees (312.5(b)(2)(ii)) | gap | As above |
| Email plus / text plus only for operators that don't disclose | 312.5(b)(2)(viii)-(ix); "disclose" in 312.2 (UNVERIFIED) | Processors are service providers, not disclosure | open | Decision 2 |
| Separate consent for third-party disclosure | 312.5(a)(2) | No disclosure to third parties for their own use | n/a | Wording (this PR): said plainly. Analytics (#28) would need it |
| Parent can review a kid's information | 312.6(a)(1), (a)(3) | Most is visible in the household; reminder log and hidden comments planner-only; export planner-only | partly | Code or decision: every guardian |
| Parent can refuse further collection and delete | 312.6(a)(2) | Withdraw unlinks at once; own content erased after 30 days; removal anonymizes at 12 months; kid's sign-in account stays | partly | Code: delete everything about a child now |
| Written retention policy: purpose, business need, deletion timeframe; nothing kept indefinitely | 312.10 | retention.md Kids (business need added in this PR) | partly | Remaining: the kid's sign-in account, list items (known gaps) |
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
| Consent before collecting | .030(1) | Agree and save, `allergy-data-v1`; server refuses without it | met | — |
| Consent request names categories, purpose, recipients, how to withdraw | .030(2) | Allergy sentence names neither recipients nor withdrawal | partly | Code: `allergy-data-v2` |
| Separate consent to share | .030(1)(b) | Nothing shared outside processors | n/a | Unless household visibility is "sharing" (decision 2) |
| Access, including third parties and their contacts | .040(1)(a) | Visible in the household; export is planner-only | partly | Policy says no third parties; access request by email |
| Withdraw consent | .040(1)(b) | Allergy alerts off erases all | met | — |
| Delete, including backups (up to 6 months) | .040(1)(c) | At once; backups 7 days | met | — |
| 45 days, one 45-day extension; free twice a year; no new account needed | .040(1)(d), (f), (g) | Was "the time the law allows" | gap → fixed | Wording (this PR) |
| Appeal: written answer in 45 days, AG contact if denied | .040(1)(h) | None | gap → fixed | Wording (this PR); AG link `[CHECK]` |
| Security and need-to-know access | .050 (text UNVERIFIED) | RLS by household | met | — |
| No sale without authorization; no geofencing | .070, .080 | Never sold; no location | n/a | — |

## Nevada SB 370 (NRS 603A.400–.550)

No size threshold or small-business exemption (603A.490 exempts HIPAA, GLBA and similar only). There's no private
right of action (603A.550). The definition's exact wording is UNVERIFIED (603A.430). One reading calls it use-based;
Foon's use, flagging a known allergy, would still count.

| Requirement | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Maintain and conspicuously link a policy | 603A.495 | consumer-health-data.md (this PR) | gap → draft | Code: links, as for Washington |
| Extra contents: processing methods, request procedure, review and correction, material changes, cross-site collection, effective date | 603A.495 (paraphrased; read the section directly) | consumer-health-data.md Nevada section | met in draft | Confirm the list against 603A.495 |
| Consent to collect, separate consent to share, disclosures in the request | 603A.500 | As Washington | partly | Code: `allergy-data-v2` |
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
| In-app account deletion | 5.1.1(v); Apple's account deletion page | Family → Your data → Delete my account | met, with a check | Code check: billing message; kid sign-in row |
| Say what's kept after deletion | Apple deletion FAQ | privacy.md Deleting | partly | Show "anonymous ratings stay" on the delete screen (code) |
| No sharing without permission, including AI | 5.1.2(i) | On-device AI; #59 queue stays in the family's devices | met | Wording (this PR): marketing line |
| Apps that collect from minors need a policy and must follow children's privacy law, even outside the Kids Category | 5.1.4(b) | Not in Kids Category | partly | See COPPA |
| Outside the Kids Category, don't suggest kids are the main audience | 2.3.8 | Keyword "kids" | partly | Wording (this PR): dropped |
| Subscription screen: name, duration, renewal price, trial, restore, Terms and Privacy links | 3.1.2; Apple's Subscriptions page | Not checked in code | gap | Code check; decision 13 |
| EULA | 3.1.2 (wording UNVERIFIED) | terms.md layers Apple's EULA | partly | Decision 12 |
| Privacy label accurate | App Privacy Details | Label rows in app-store-submission.md | partly | Check whether the push token is "Device ID" and whether kept request logs (IPs) count (both UNVERIFIED); add the age range with #88 |

## Apple age ratings and Declared Age Range (2026)

| Requirement | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Answer the new age-rating questions (4+/9+/13+/16+/18+); updates were blocked after 2026-01-31 | Apple news 2025-07-24 | Not re-answered against the new questions | partly | Decision 11 |
| Answer honestly | 2.3.6 | — | partly | Same |
| Declared Age Range API, iOS/macOS 26+; `confirmed` from iOS 26.5 | Apple Age Assurance page | Not built | gap | Code (#88) |
| Developers handle their own age limits | Apple Age Assurance page | Terms say 18+, nothing checks | gap | Code (#88) and decision |
| Significant Change and `RESCIND_CONSENT` notifications where required | Apple Age Assurance page | Not built | gap | Code, where `requiredRegulatoryFeatures` says so |

## App-store age laws

Status as of 2026-11-06:

- **Texas SB 2420.** In force. The Fifth Circuit stayed the injunction (2026-06-04), and the Supreme Court declined to
  vacate the stay (2026-07-06). The merits appeal was argued 2026-08-04, with no decision found (later events
  **UNVERIFIED**).
- **Utah, Louisiana and California.** Later dates, from secondary sources (**UNVERIFIED**).

| Requirement on a developer | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Texas: rate the app and each purchase, and tell the store | SB 2420 §121.052 | Questionnaire not re-answered | partly | Decision 11 |
| Texas: tell the store before a significant change to terms or privacy policy | §121.053 | Not planned | gap | Code or process |
| Texas: verify each user's age category and a minor's consent | §121.054 | Not built | gap | Code (#88); good-faith reliance on the store's data is a safe harbor (§121.056(c)) |
| Texas: use store data only for listed purposes, and delete it after verification | §121.055(a)-(b) | retention.md planned to keep the age range | gap | Code or design (decision 6); note in retention.md (this PR) |
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

| Requirement | Citation | Where we meet it | Verdict | Fix |
| --- | --- | --- | --- | --- |
| Accurate headers | FTC guide 1 | `WAITLIST_FROM` on a Resend-verified domain | met | Confirm the production value |
| Honest subject | FTC guide 2 | "Confirm your spot on the Foon waitlist" | met | — |
| Identified as an ad, unless the recipient opted in | FTC guide 3 | Opt-in | met | Recheck with the first offer email |
| Valid postal address | FTC guide 4 | None in the email or the policy | gap | Code: email footer; wording (this PR): `[ADDRESS]` |
| Clear opt-out, honored in 10 business days, working 30+ days | FTC guide 5, 7 | Unsubscribe link, one-click `List-Unsubscribe`, deletes at once, link doesn't expire | met | Optional: keep a suppression hash |
| Transactional only if confirming is the main purpose | 16 CFR 316.3 (UNVERIFIED) | The confirmation pitches the founding offer | partly | Drop the pitch, or add the address and treat it as commercial |
| Responsible for mail sent on your behalf | FTC guide 8 | Resend | met | — |
