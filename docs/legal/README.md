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
- [ ] Parental consent method: today a signed-in parent agrees in the app when inviting a kid (`parental-invite-v2` since #276; earlier consents are v1 until #277 asks again),
      logged with who, when and the wording. Is that a sufficient verifiable-consent method?
- [ ] Kids' self-entered content: erased 30 days after a parent withdraws consent; anonymized 12 months after a kid is
      removed, with ratings kept as anonymous history. Is the hard delete, and is keeping anonymous ratings, acceptable?
- [ ] A withdrawn or removed kid's sign-in account (Apple ID and email) isn't deleted automatically. Should it be?
- [ ] New consent for material changes to the privacy policy: how should the app ask?
- [ ] Postal address in the notice (`[ADDRESS]`), and whether a phone number is needed (312.4(d)(1)).
- [ ] Is email plus (312.5(b)(2)(viii)) the right consent method for Foon, and is a kid's name or comment being seen by
      their own household a "disclosure" under 312.2 (which would rule it out)?
- [ ] The written information security program (312.8(b)): who is named, and what goes in it.
- [ ] Texas SB 2420 (§121.053–121.055): store notice before significant policy changes, age verification, and
      deleting the App Store's age data after use.
- [ ] Age at sign-up: the app doesn't check it today (Apple's age range check is #88). Is that acceptable, along with
      Texas's App Store Accountability Act?

### Allergies as health data

- [ ] consumer-health-data.md: does it meet Washington (RCW 19.373.020) and Nevada (NRS 603A.495), and is the opt-in
      (Agree and save, logged as `allergy-data-v1`) enough consent? The sentence doesn't yet name recipients or how to
      withdraw (compliance-check.md proposes `allergy-data-v2`).
- [ ] Is household members seeing each other's allergies "sharing" with a third party (RCW 19.373.010(27))?
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

- Withdrawing consent or removing a kid unlinks their sign-in account but doesn't delete it.
- Consent records are erased with the household; there's no record kept afterwards.
- Owner transfer isn't built yet (spec, Outliers), so the drafts say it's planned.

Found by the compliance self-check ([compliance-check.md](compliance-check.md), "Before launch" (b) has the detail):

- Parental consent is an in-app agreement, not a method listed in COPPA 312.5(b)(2).
- There's no way to ask parents for new consent after a material change.
- There's no "delete everything about this child now"; the 30-day and 12-month delays apply.
- Only planners can see a kid's reminder log and hidden comments, and only planners can export.
- The allergy consent sentence doesn't name who receives allergies or how to withdraw.
- No links yet to the privacy policy or the consumer health data policy on the homepage, the App Store page, onboarding
  or Your data. (The paywall and the kid invite and join screens have their links, #282 and #276.)
- Age assurance (#88) isn't built: Texas SB 2420 is in force; California, Utah and Louisiana follow in 2027.
- No notice to the App Store before a significant change to the terms or privacy policy (Texas §121.053).
- The waitlist email has no postal address, and the confirmation email includes an offer.
- The delete-account screen doesn't say billing continues through Apple or how to cancel.
- Allergy consent is one household-wide agreement, and only parents can withdraw it or change allergies. An adult who
  isn't a parent can't remove their own allergies in the app.

## After review

1. Fold the lawyer's changes into these files and remove the DRAFT headers, `Review` notes and `[CHECK]` marks.
2. Publish the privacy policy at getfoon.com/privacy and the terms at getfoon.com/terms (web/app/pages), with the
   retention policy linked from the privacy page. Update the "Last updated" dates. Publish the consumer health data
   policy on its own page, linked prominently from the homepage, the App Store page and the app (RCW 19.373.020(1)(b)).
3. Enter the URLs in App Store Connect (privacy policy URL; terms as the EULA or in the description) and check the
   privacy label.
4. Show the terms and privacy policy in the app: linked from the paywall, onboarding and Family → Your data.
5. Update What Foon keeps (the in-app summary) and docs/spec.md if anything changed.
