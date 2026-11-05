# Foon legal drafts (#67)

**DRAFT — pending legal review. Not yet in effect.**

These are drafts of Foon's legal documents, written for a lawyer to review before launch:

- [privacy.md](privacy.md): the privacy policy.
- [terms.md](terms.md): the terms of use.
- [retention.md](retention.md): the data retention policy, which the amended COPPA rule requires in writing.

## Status

- Drafts only. Nothing here is published, and none of it is in effect.
- The website keeps its short plain-English summaries at getfoon.com/privacy and /terms until review is done.
- Every factual statement is meant to be true of the code on `main`, plus the retention changes in #67 car 1 (marked
  "(#67 car 1)"). Where we weren't sure, the text says `[CHECK]`. Legal questions are marked `> **Review:**` inline.
- The documents say "Foon" throughout and name the legal party once: The Recruiting Compass LLC.
- Governing law: Ohio. Contact: support@getfoon.com.
- Analytics and crash reporting don't exist yet (#28), so the drafts don't mention them. When they're added, the
  privacy policy, retention policy, App Store label and "no tracking" claims need another look first.

## Reviewer checklist

### Kids and COPPA

- [ ] The amended COPPA rule (compliance date April 22, 2026): does a parent-run household app, outside the Kids
      category, with kids joining only by a parent's invite, meet it?
- [ ] Written retention policy: does retention.md's "Kids: purposes and periods" section meet the requirement?
- [ ] Parental consent method: today a signed-in parent agrees in the app when inviting a kid (`parental-invite-v1`),
      logged with who, when and the wording. Is that a sufficient verifiable-consent method?
- [ ] Kids' self-entered content: erased 30 days after a parent withdraws consent; anonymized 12 months after a kid is
      removed, with ratings kept as anonymous history. Is the hard delete, and is keeping anonymous ratings, acceptable?
- [ ] A withdrawn or removed kid's sign-in account (Apple ID and email) isn't deleted automatically. Should it be?
- [ ] New consent for material changes to the privacy policy: how should the app ask?
- [ ] Postal address in the notice.
- [ ] Age at sign-up: the app doesn't check it today (Apple's age range check is #88). Is that acceptable, along with
      Texas's App Store Accountability Act?

### Allergies as health data

- [ ] Allergies may be consumer health data under Washington's My Health My Data Act and similar laws (e.g. Nevada,
      Connecticut). Do we need a separate consumer health data policy, and is the opt-in (Agree and save, logged as
      `allergy-data-v1`) enough consent?
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

## After review

1. Fold the lawyer's changes into these files and remove the DRAFT headers, `Review` notes and `[CHECK]` marks.
2. Publish the privacy policy at getfoon.com/privacy and the terms at getfoon.com/terms (web/app/pages), with the
   retention policy linked from the privacy page. Update the "Last updated" dates.
3. Enter the URLs in App Store Connect (privacy policy URL; terms as the EULA or in the description) and check the
   privacy label.
4. Show the terms and privacy policy in the app: linked from the paywall, onboarding and Family → Your data.
5. Update What Foon keeps (the in-app summary) and docs/spec.md if anything changed.
