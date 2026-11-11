# Foon legal drafts (#67)

**DRAFT — pending legal review. Not yet in effect.**

These are drafts of Foon's legal documents, written for a lawyer to review before launch:

- [privacy.md](privacy.md): the privacy policy.
- [terms.md](terms.md): the terms of use.
- [retention.md](retention.md): the data retention policy, which the amended COPPA rule requires in writing.
- [consumer-health-data.md](consumer-health-data.md): the separate Consumer Health Data Privacy Policy for allergies
  (Washington's My Health My Data Act, Nevada).
- [compliance-check.md](compliance-check.md): our own check of these drafts against COPPA, the state health-data laws,
  Apple's rules, app-store age laws and CAN-SPAM (2026-11-06). Not legal advice: start the review there.

## Who reviews

Either a lawyer, or, for the kids' privacy part, an FTC-approved COPPA Safe Harbor program, which reviews the app and
the policy against COPPA and checks again each year: CARU, ESRB, iKeepSafe, kidSAFE, PRIVO or TRUSTe (from the FTC's
list, 2026-11-06). A Safe Harbor program doesn't cover the terms or the state health-data laws.

## Status

- Drafts only. Nothing here is published, and none of it is in effect.
- The website keeps its short plain-English summaries at getfoon.com/privacy and /terms until review is done.
- Every factual statement is meant to be true of the code on `main`. Where we weren't sure, the text says `[CHECK]`. Legal questions are marked `> **Review:**` inline.
- The documents say "Foon" throughout and name the legal party once: The Recruiting Compass LLC.
- Governing law: Ohio. Contact: support@getfoon.com.
- Analytics and crash reporting don't exist yet (#28), so the drafts don't mention them. When they're added, the
  privacy policy, retention policy, App Store label and "no tracking" claims need another look first.

## Reviewer checklist

### Kids and COPPA

- [ ] The amended COPPA rule (compliance date April 22, 2026): does a parent-run household app, outside the Kids
      category, with kids joining only by a parent's invite, meet it?
- [ ] Written retention policy: does retention.md's "Kids: purposes and periods" section meet the requirement?
- [ ] Parental consent method: email plus since #275 (`parental-invite-v3`): a notice to the asking parent's sign-in
      email, agreement on getfoon.com, then a confirming email with a withdraw link; consent counts once that has
      gone out. Consents given in the app before (v1, v2) no longer count since #277: those kids are signed out (no
      erase clock) until a parent agrees by email plus. Is the notice (email 1)
      enough under 312.4(c)(1), and is a typed address for an account with no email acceptable?
- [ ] Kids' self-entered content: erased 30 days after a parent withdraws consent; anonymized 12 months after a kid is
      removed, with ratings kept as anonymous history. Is the hard delete, and is keeping anonymous ratings, acceptable?
- [ ] A withdrawn or removed kid's sign-in account (Apple ID and email) isn't deleted automatically. Should it be?
      (A parent can delete it at once with Delete everything about a kid, #278.)
- [ ] Delete everything about a kid (#278) deletes the kid's parental consent record too, and can't revoke Foon's
      Sign in with Apple token. Are both acceptable? (retention.md, Kids.)
- [ ] New consent for material changes to the privacy policy: how should the app ask?
- [ ] Whether a phone number is needed in the notice (312.4(d)(1)). The postal address is set (#284).
- [ ] Is email plus (312.5(b)(2)(viii)) the right consent method for Foon, and is a kid's name or comment being seen by
      their own household a "disclosure" under 312.2 (which would rule it out)?
- [ ] The written information security program (312.8(b)): who is named, and what goes in it.
- [ ] Texas SB 2420 (§121.053–121.055): store notice before significant policy changes, age verification, and
      deleting the App Store's age data after use.
- [ ] Age at sign-up: the app doesn't check it; Apple's age range is asked only when someone claims a profile (#88).
      Is that acceptable, along with Texas's App Store Accountability Act?

### Allergies as health data

- [ ] consumer-health-data.md: does it meet Washington (RCW 19.373.020) and Nevada (NRS 603A.495), and is the opt-in
      (Agree and save, logged as `allergy-data-v2` since #280, which names recipients and how to withdraw) enough
      consent?
- [ ] Households that agreed to `allergy-data-v1`, which named neither, are asked again since #277 (Chris reversed
      the 2026-11-07 call on 2026-11-09): existing allergies keep flagging and nobody adds one until a parent agrees
      to v2. Is keeping the v1 allergies flagging meanwhile acceptable?
- [ ] Is household members seeing each other's allergies "sharing" with a third party (RCW 19.373.010(27))?
- [ ] An adult can add and remove their own allergies in the app (#285), and a parent can add them again under the
      household's agreement: Chris decided not to block that (2026-11-07, #294). Is that enough for withdrawal
      (RCW 19.373.040(1)(b))?
- [ ] An adult who isn't a parent agrees for their own allergies (`own-allergy-v1`, #277) before adding one, and
      the agreement is logged; until they do, the ones they already have keep flagging (Chris, 2026-11-09: safety).
      Is that their consent under RCW 19.373.030(1)(a)?
- [ ] Turning allergy alerts off also clears every note on the household's list lines, and someone's allergies all
      going takes the list notes naming them, or that might (#280). Notes are free text, so that's matched by name:
      confirm it's enough. A custom allergy typed with "; " in it can leave a part naming no one ("Check for nuts")
      until alerts go off or the list is rebuilt.
- [ ] Connecticut SB 1295: does the whole CTDPA reach Foon from 2026-07-01 because it processes sensitive data?
- [ ] New York S9269 (Health Information Privacy Act): signed or not, before launch.
- [ ] The allergy disclaimer in terms section 5: is it prominent and strong enough?

### Privacy laws

- [ ] Which US state privacy laws apply to a company our size, and are the rights, response times and appeal process in
      "Your rights" right? Is a California-specific notice needed?
- [ ] Data processing agreements with Supabase, Resend and Vercel.
- [ ] Provider logs (Supabase sign-in and request logs, Vercel request logs): list them and their periods?
- [ ] Encryption at rest and breach notice wording.

### App Store

- [ ] The privacy policy URL and terms are required by App Store Connect; the paywall must link both and show price,
      period, trial length and auto-renewal terms.
- [ ] Apple's standard EULA vs. our own terms with Apple's required clauses.
- [ ] The App Store privacy label in [app-store-submission.md](../app-store-submission.md) matches the policy.

> **Review:** Foon computes pooled weekly totals across all households (`internal.metrics()`, #36, see
> [metrics.md](../metrics.md)): nothing new is stored, and nothing is shown for fewer than 5 households. Should the
> App Store label list "Analytics" as a purpose for the data it reads? The analytics and crash rows stay removed until
> #28.

### Terms

- [ ] The LLC and a DBA: should "Foon" be registered as a trade name for The Recruiting Compass LLC, and how should the
      party be named?
- [ ] Arbitration and class-action waiver: left out. Add them, or a small-claims option?
- [ ] Indemnity: appropriate for a consumer family app?
- [ ] Limitation of liability cap ($50 or 12 months' fees) and personal-injury carve-outs.
- [ ] Beta and founding-family terms: what "locked for life" binds us to, whether the 50-family cap is promised, and
      how the beta ends. The spec is short on these.
- [ ] Free trial wording ("30 days" in the spec; one month in the App Store products) and auto-renewal disclosures.
- [ ] Recipe imports: copyright position and whether a takedown contact is needed.
- [ ] The shutdown/export promise in section 11.

### Backups

- [ ] Production is on Supabase Free (no backups) for now and moves to Pro (daily backups kept 7 days) once there are
      customers. The policy's "deleted data can remain in backups for up to 7 days" covers both.

## Known gaps between the code and these drafts

The drafts describe what the code does today. These are the places where that may not be what we want:

- Withdrawing consent or removing a kid unlinks their sign-in account but doesn't delete it (Delete everything about a
  kid does, #278).
- Consent records are erased with the household; there's no record kept afterwards.
- Owner transfer isn't built yet (spec, Outliers), so the drafts say it's planned.

Found by the compliance self-check ([compliance-check.md](compliance-check.md), "Before launch" (b) has the detail):

- Parental consent is by email plus since #275. Consents given in the app before it (v1, v2) stay active but no longer
  count since #277 put v3 in force: those kids are signed out until a parent agrees again by email plus.
- Resend's log retention for the consent emails isn't confirmed (retention.md).
- Since #277 a changed wording is asked again (Wording versions, below). Terms and Privacy are asked by the app only
  for now; the server enforces them once no supported build lacks the prompt (Chris, 2026-11-09).
- Households that agreed to the first allergy consent (`allergy-data-v1`), which named neither who receives allergies
  nor how to withdraw, are asked again since #277 (Chris reversed the 2026-11-07 call on 2026-11-09): their allergies
  keep flagging, and nobody adds one until a parent agrees to v2.
- The app links the policies (#281): Terms and Privacy on the agreement screen, join a family, the paywall and the kid
  invite; Privacy and the Consumer Health Data Policy in Family → Your data; the Consumer Health Data Policy in Allergy
  alerts and beside every allergy agreement. Every page on getfoon.com links both in its footer, and
  getfoon.com/consumer-health-data is a plain summary until the reviewed policy replaces it. Still to do after review:
  the App Store description's links, and whether a footer link is "prominent" enough on the homepage
  (RCW 19.373.020(1)(b)).
- Age assurance (#88) is partly built: the age range is asked when someone claims a profile, and a significant-change
  hook exists (iOS 26.4+, no change qualifies yet); consent revoked through Apple waits for Phase 4. Texas SB 2420 is
  in force; California, Utah and Louisiana follow in 2027.
- Which changes to the terms or privacy policy count as significant (Texas §121.053) isn't decided.
- The delete-account screen doesn't say billing continues through Apple or how to cancel.
- Allergy consent is one household-wide agreement, and only parents can give or withdraw it for the household or
  change anyone's allergies. An adult can add and remove their own in the app (#285), adding only under that
  agreement, and a parent can add them again after the adult removes them.

## Wording versions

Every agreement names the wording it was given to (#277). The registry is `public.agreement_versions`: one row per
version, ordered within its kind. The newest row with `effective_at <= now()` is in force; an agreement to an older one
still counts unless a version after it has `requires_reagreement`.

The registry shipped dormant (#277 PRs A to C: nothing in force). `20261119000000_agreements_in_force.sql` (PR D) set
`effective_at` to the moment it ran for the versions marked in force below, and held everyone whose agreement was
older in the same migration. So the date each came into force is the day that migration reached each database: staging
when PR D merged, production when it was deployed. Read the exact dates from the registry (read only):

```sql
select kind, version, effective_at from public.agreement_versions order by kind, ordinal;
```

| Kind | Versions | In force | Where the words live |
| --- | --- | --- | --- |
| Household allergy data | `allergy-data-v1`, `allergy-data-v2` | `allergy-data-v2` | The app's statement and `textVersion` (iOS) |
| An adult's own allergies | `own-allergy-v1` | `own-allergy-v1` | The app |
| A kid's parental consent | `parental-invite-v1` (in app), `-v2` (in app), `-v3` (email plus) | `parental-invite-v3` | `supabase/functions/parental-consent/email.ts` (`TEXT_VERSION`) and web/app/pages/consent |
| Terms | `terms-draft-v1` | `terms-draft-v1` | getfoon.com/terms; label `TERMS_VERSION` in web/app/content.ts |
| Privacy | `privacy-draft-v1`, `privacy-draft-v2` (#48: the emails) | `privacy-draft-v2` | getfoon.com/privacy; label `PRIVACY_VERSION` in web/app/content.ts |
| Weekly plan email (opt-in) | `weekly-plan-email-v1` | `weekly-plan-email-v1` | The app's switch (`EmailOptIn.textVersion`, iOS) |
| Founding-family updates (opt-in) | `founding-updates-v1` | `founding-updates-v1` | The app's switch (`EmailOptIn.textVersion`, iOS) |

`20261126000000_privacy_v2_in_force.sql` (#48 PR D) did the same for `privacy-draft-v2` and the two opt-in wordings.
Every adult who agreed to `privacy-draft-v1` sees the app's "We updated our terms" gate once; nothing is held.

`allergy-data-v1` and `parental-invite-v1` have no `effective_at`: they were in use before the registry existed, and
an agreement to either is outdated because a later version in force requires agreeing again.

When wording changes, whoever agreed to an older version is asked again: households can't add allergies, adults see
the Terms prompt, and a kid is signed out (nothing erased) while every parent with a verified email gets a renewal
email, and a reminder after 7 days (parental-consent.md).

### Changing wording later

1. **Allergy**: change the app's statement and its `textVersion`; add a registry row (next ordinal, a one-sentence
   `summary` of what changed) with a future `effective_at`. Ship the app build before that date.
2. **Kid consent**: add the registry row with a future `effective_at`, deploy the function with the new
   `TEXT_VERSION` and words (and the /consent page), then let the row take effect. The function sends any registered
   wording at or after the one in force, so emails keep going throughout.
3. **Terms or Privacy**: change the page text and its label in content.ts; add the registry row.
4. **A typo fix** that changes nothing promised: still a new version, with `requires_reagreement = false`, so nobody
   is asked again.

Registry rows come in a new migration; never edit an applied one.

## After review

1. Fold the lawyer's changes into these files and remove the DRAFT headers, `Review` notes and `[CHECK]` marks.
2. Publish the privacy policy at getfoon.com/privacy and the terms at getfoon.com/terms (web/app/pages), with the
   retention policy linked from the privacy page. Update the "Last updated" dates. Publish the consumer health data
   policy on its own page, linked prominently from the homepage, the App Store page and the app (RCW 19.373.020(1)(b)).
3. Enter the URLs in App Store Connect (privacy policy URL; terms as the EULA or in the description) and check the
   privacy label.
4. Show the terms and privacy policy in the app: linked from the paywall, onboarding and Family → Your data.
5. Update What Foon keeps (the in-app summary) and docs/spec.md if anything changed.
