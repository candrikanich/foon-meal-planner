# Foon Data Retention Policy

**DRAFT — pending legal review. Not yet in effect.**

Last updated: [date of publication]

Foon is an app made by The Recruiting Compass LLC ("Foon", "we", "us"). This policy says how long Foon keeps each kind
of data, what starts its deletion, and where in our systems that's enforced. It goes with our
[Privacy Policy](privacy.md).

Our rule: keep what a family needs for its own dinner history while the household exists, and delete everything else on
a schedule. We aim to keep data only as long as this policy describes, except in backups (see Backups) or where the law
requires.

## How deletion runs

Scheduled jobs run in the database (pg_cron), every day unless noted. Times are UTC.

| Key | Job | Defined in (newest definition) | Runs |
| --- | --- | --- | --- |
| A | `anonymize_expired_profiles()` | `20261110000000_retention_cleanup.sql` | Daily, 03:17 |
| P | `prune_push_outbox()` | `20261102210000_store_run.sql` | Daily, 03:29 |
| S | `prune_subscription_events()` | `20261107000000_entitlement.sql` | Daily, 03:41 |
| T | `prune_shopping_trips()` | `20261122000000_shopping_trips.sql` | Daily, 03:53 |
| M | `prune_email_outbox()` | `20261121000000_account_email.sql` | Daily, 03:47 |
| W | `prune_waitlist()` | `20261108000000_waitlist.sql` | Daily, 04:17 |
| C | `purge_parental_consent_requests()` | `20261116000000_email_plus_consent.sql` | Daily, 04:23 |
| J | `expire_ai_jobs()` | `20261103210000_ai_jobs.sql` | Hourly, :41 |
| E | `erase_household()` | `20261117000000_agreements.sql` | On Delete household or the owner's account delete |
| D | `delete_account_data()` | `20261103040000_kid_delete_own_words.sql` | On Delete my account |
| K | `delete_kid()` | `20261117000000_agreements.sql` | On a parent's Delete everything about a kid |

Because a daily job runs once a day, a period can run up to a day longer than stated (for example, "1 day" can be up to
2 days).

## Kept while the household exists

The household's own dinner history. All of it is erased at once when the household is deleted (job **E**, and the
`delete-account` Edge Function removes its photos first).

| Data | Purpose |
| --- | --- |
| Household name, emoji, time zone, owner, settings, founding flag | Running the household |
| Profiles: first name, avatar, adult or kid, parent, role, status, away dates, schedule | Who's in the family |
| Allergies (`member_allergies`) | Flagging dishes; see below for earlier deletion |
| Allergy and parental consent records (`consents`, `consent_agreements`: who agreed to which wording, when, how) | Proof of consent |
| Agreement holds (`agreement_holds`): what was agreed, what was needed, when access was held and released, and why (#277) | Proof Foon asked again when a wording changed |
| Meals, ingredients, sides, traditions | The family's library |
| Meal photos (private Storage bucket `household-photos`) | Showing the dish; a replaced photo is deleted once the dish shows the new one (`set_meal_photo()`, then the app) |
| Plans, nights, attendance, saved schedules | The week's plan |
| Shopping lists, items, freezer stash | Shopping and stock |
| Meal logs, reactions (ratings and comments), hidden comments, chef thanks | After-dinner history |
| Serving notes, requests and "me too"s, night claims | Everyone's say |
| Corrected receipt lines (`receipt_aliases`) | Reading the next receipt |
| Subscription status (`household_subscriptions` and the household's columns) | Entitlement |

Consent records keep the ID of the account that agreed, without a database link to it, so they stay with the household
when that parent deletes their account. They're erased with the household. A kid's parental consent record, their
agreements and their hold are deleted when a parent deletes everything about that kid (job **K**).

A hold keeps a held kid's account ID only while the hold is open, to link the account back when a parent renews; it's
cleared when the hold ends (renewed, withdrawn, removed), and set empty if the account is deleted first (#277; holds
open since the new wordings came into force, `20261119000000_agreements_in_force.sql`).

> **Review:** should consent records be kept for a period after a household is deleted, as proof of consent? Today they
> are erased with it.

## Deleted on a schedule

| Data | How long | Starts when | Enforced by |
| --- | --- | --- | --- |
| Tonight polls and their votes | 8 weeks | Poll created | A |
| Plan activity (`plan_changes`) | 8 weeks | Change made | A |
| Reminder log (`notification_log`): kind, night, times | 8 weeks | Row created | A |
| Push notifications queued or sent (`push_outbox`) | 8 weeks | Row created | P |
| Account emails queued, sent or dropped (`email_outbox`: kind, dates and ids, never an address) | 30 days | Row created | M |
| "Heading to the store" runs (`store_runs`) | 1 day | Run ends | P |
| Finished shopping trips (`shopping_trips`; only trips where something was bought): household and time only, for the internal metrics (#260) | 13 months | Trip finished | T |
| AI job recipe lines (`ai_jobs.payload`) | Until the job ends; 3 days max | Job queued | J (hourly), trigger |
| AI job and its copy of the tidied result | 30 days | Job finishes | J |
| Apple subscription notices (`subscription_events`) | 2 years | Notice received | S |
| Invites | 30 days | Invite expires (7 days), is redeemed or is cancelled | A |
| Invite-code attempts, wrong or right (`invite_redeem_attempts`) | 1 day | Attempt | A |
| Daily recipe-import counts (`import_usage`) | 7 days | Import day (UTC) | A, and `claim_import_slot()` on each import |
| Parental consent requests (`parental_consent_requests`): kid, parent who asked, status, times | 30 days | Request ends: confirmed, refused, cancelled, or its 7-day link lapses | C |
| An email address a parent typed for a consent request (their account had none) | Until the confirming email is sent or the request ends: at most 7 days, and up to a day more | Typed | `activate_parental_consent()`, the request's end, C |
| Consent email bookkeeping (`parental_consent_sends`: who asked, when) | 1 day | Send | C |
| Renewal requests for a held kid (#277): one per parent with a verified email, and one reminder 7 days on | 30 days, as other consent requests | Request ends | C |

## People who leave

When a parent removes someone from the household:

- **At once:** their account loses access, and their push devices and pending pushes are deleted
  (`members_drop_push_devices` trigger, `20261102200000_push_car4.sql`). Their part of saved schedules is deleted
  (`20261030200000_away_dates_templates.sql`).
- **12 months later, a removed kid** is anonymized (job **A**): the first name becomes "Former member", and the avatar,
  schedule, notification settings, age range, allergies, serving notes, comments, notes on requests and reminder log go.
  Open offers to cook are released.
- **12 months later, a removed adult** is anonymized the same way (job **A**).
- **Kept without a name:** their ratings, requests' titles and cooking history, as the family's history.

## Kids: purposes and periods

The amended COPPA rule asks for a written retention policy for children's information. Foon keeps a kid's information
only to run their family's dinner planning: to show who's home, flag their allergies, and let them request, vote, rate
and help. We never use it for ads, never sell it, and never send it anywhere for AI.

| A kid's data | Purpose | Why we need it that long | How long |
| --- | --- | --- | --- |
| Profile a parent enters: name, avatar, schedule | Who's home | The plan is built around who's home each night | In the household; anonymized 12 months after removal |
| Allergies a parent enters | Flagging dishes | Every new dish and list is checked against them | Until removed, alerts off, or anonymized |
| Parental consent record: who agreed, when, how (email plus, or in the app before #275), when the confirming email went out, the wording | Proof a parent agreed | To show consent was given, while the kid's information exists | While the household exists, or until a parent deletes everything about the kid |
| Consent requests about the kid (status, times, and whether it was a first consent or a renewal) | Asking a parent by email | Shows the parent where the request stands, and keeps the withdraw link working | 30 days after the request ends; at once if a parent deletes everything about the kid |
| Agreement hold (#277): wording agreed and needed, when held and released, why; their account ID while held | Asking a parent again when the consent wording changes | Proof the kid was signed out until a parent agreed; the account ID links them back | Hold: while the household exists, or until a parent deletes everything about the kid. Account ID: until the hold ends |
| Apple account ID and email (from Sign in with Apple), and first name if Apple shares it | Signing in | Needed for each sign-in | Until the kid deletes their account, or a parent deletes everything about them. The bare account ID in their Terms and Privacy acceptances stays after the kid deletes their account (see Deleting below) |
| Apple age range (#88, not yet used) | Age checks | See the note on Texas below | Until consent is withdrawn (30 days) or the account is deleted |
| What they enter (ratings, comments, votes) | Family planning | It's the family's dinner history, which planning draws on | As for all; erased 30 days after withdrawal |
| Their device's push token | Reminders | Needed to deliver each reminder | Until sign-out, reminders off, unlinking, or removal |
| Reminders sent to them | Budgets, quiet hours | To keep to the daily reminder budget and quiet hours | 8 weeks, or sooner: see below |

Everything a household holds about a kid is deleted when the household is deleted. Their sign-in account stays (see
the note below), unless a parent deletes everything about them first.

> **Review:** Texas's App Store Accountability Act (SB 2420, §121.055(b)) says a developer must delete the age data it
> gets from the App Store once it has used it to verify age. If #88 stores Apple's age range as planned above, that
> conflicts. Decide whether to keep only a derived kid/adult flag. See compliance-check.md.

> **Review:** withdrawing consent or removing a kid unlinks their sign-in account but doesn't delete it, so the Apple
> account ID and email Foon's sign-in service holds for them stay until the kid (or someone with their device) deletes
> the account, or a parent deletes everything about the kid (job **K**, below). Decide whether withdrawing or removing
> should also delete it. [CHECK]

**When a parent withdraws a kid's consent** (`consents_unlink_on_parental_revoke` trigger,
`20261026205731_parental_consent_and_retention.sql`): the kid's account is unlinked at once and loses access to the
household. If consent isn't given again, after 30 days (job **A**) Foon deletes the ratings, thank-yous, serving
notes, requests and "me too"s, offers to cook, poll votes and plan changes the kid entered themselves, and the reminder
log and pushes about them. It clears their comments, and stops naming them in polls, digests and on list lines (who
marked a line for tonight, who ticked it off). The lines themselves stay: a line records no author and merges
everyone's adds of the same item, so it's the family's. Their age range is cleared. What a parent entered for them
stays while they're in the family.

**When a parent deletes everything about a kid** (job **K**, any parent, on the kid's profile; #278, for COPPA
312.6): everything goes at once, in one transaction, with no 30-day or 12-month wait. Deleted: the profile itself (not
anonymized), allergies, ratings and comments (hidden ones too), thank-yous the kid sent and the ones sent for a dinner
they cooked, serving notes about them or written by them, their requests with their "me too"s and their own "me too"s,
offers to cook, attendance on every night, poll votes, plan changes they made, the reminder log, push devices and
pushes for or about them, a store run they started, invites for them, their parental consent record, their part of
saved schedules and dinner jobs, invite guesses, and their sign-in account (Apple account ID and email; its sessions
end, so their device loses access). Kept, without naming them: plans and nights, dishes (no longer saying the kid makes
one), dinners logged (the cook and confirmer cleared), polls they started, a planner's daily digest, and shopping list
lines. List lines record no author and merge everyone's adds, so a kid's lines stay with the family's list and only
stop saying who checked them off or marked them for tonight. Something the kid entered for someone else (a rating,
request, "me too", offer or vote) stays that person's, without saying who entered it; a note the kid wrote on such a
request is cleared. A dish their "not for me" helped retire stays retired. Supabase's own
auth audit log keeps the account's email for its usual time, as it does when anyone deletes their account.

> **Review:** deleting everything about a kid deletes the record that a parent consented for them, because the parent
> asked for everything about the kid to go. Confirm no record of the consent needs to be kept once the kid's
> information is gone (and if it does, for how long and with what in it).

> **Review:** a parent deleting a kid's sign-in account can't revoke Foon's Sign in with Apple token, which needs a
> fresh sign-in by the kid. Foon then holds nothing about the kid, but Foon can still appear in the kid's Apple ID
> settings until they remove it. Confirm that's acceptable.

**When a kid deletes their own account** (job **D**, then the `delete-account` Edge Function deletes the sign-in
account itself): their profile is unlinked; their comments, their own poll votes,
the serving notes they wrote and the notes on requests they made themselves are deleted, their offers to cook are
released, and the reminder log about them is deleted. The parent-entered profile stays.

## Allergies

- **A parent removes someone's allergies:** deleted at once; no consent needed (`set_member_allergies()`).
- **An adult removes their own,** one or all: deleted at once, the same way (`set_member_allergies()` or a single
  row, #285).
- **A guardian turns allergy alerts off:** consent is revoked and every allergy in the household is erased at once
  (`revoke_allergy_consent()` and the `consents_erase_on_revoke` trigger).
- **An adult deletes their account:** their allergies are deleted at once (job **D**).
- **A removed person is anonymized:** their allergies are deleted (job **A**).
- **A parent deletes everything about a kid:** the kid's allergies are deleted at once (job **K**).
- **The household is deleted:** all are erased (job **E**).

**Allergy notes on list lines** ("Get dairy-free (Nora)") go with the allergies (#280,
`20261114000000_allergy_notes_erase.sql`):

- **Allergy alerts off:** every note on the household's list lines, bought ones too, is cleared at once, and no line
  keeps a note while they stay off, so a phone with an old cache or queued change can't write one back. A note is free
  text, so "Couldn't find it last trip" goes too.
- **Someone's allergies all gone** (removed by a parent or by themselves, their account deleted, anonymized, or the kid
  deleted): the parts of every note that name them, or might, go at once, and the weeks whose lines changed ask the
  planner to Update the list, which puts back what everyone else still needs. A note names people in parentheses at its
  end. A part that might be theirs goes too: a short list like "(Nora +2)", which hides the others' names, and a part cut
  off inside its parentheses at the length limit.
- **Someone without allergies deleted or anonymized:** only parts that name them go, so the family's grouped warnings
  stay.
- **Some of someone's allergies removed, not all:** their notes stay until the next Update the list rebuilds them.
  A phone offline since before the removal could still send an old note naming them.
- **A custom allergy typed with "; " in it** ("nuts; seeds"): whenever someone's notes go, it can leave a part
  naming no one ("Check for nuts") until allergy alerts go off or Update the list rebuilds the line.

## Accounts

- **The owner deletes their account:** the household is erased, as for Delete household, then the account
  (`delete-account` Edge Function, jobs **D** and **E**).
- **Another adult deletes their account:** their profile is anonymized at once ("Former member"). Allergies, settings,
  schedule, serving notes, comments, request notes and reminder log are deleted. Ratings and cooking history stay
  without a name (job **D**).
- **A kid deletes their account:** see Kids above (job **D**).
- **A parent deletes everything about a kid:** the kid's information and sign-in account go at once; see Kids above
  (job **K**).
- **Terms and Privacy acceptances** (`account_agreements`, #277): which wording each account accepted, when, where in
  the app and the app's version. Kept after the account is deleted, as proof of what was agreed: the record holds the
  account ID with no database link to it, and nothing else about the person. Deleted with the account only when a
  parent deletes everything about a kid (job **K**). Neither `delete_account_data()` nor the `delete-account` Edge
  Function touches it. Asked by the app since `terms-draft-v1` and `privacy-draft-v1` came into force (#277), and again
  for `privacy-draft-v2` (#48). An adult turning on an opt-in email (#48) logs their agreement to its wording here too
  (`weekly-plan-email-v1`, `founding-updates-v1`, context `opt_in`), kept the same way.
- **Any account:** Foon's Sign in with Apple token is revoked first; if Apple refuses, nothing is deleted. Push devices,
  import counts and invite guesses are deleted, then the sign-in account itself (`delete-account` Edge Function, job
  **D**, foreign-key cascades).
- **Delete household:** everything is erased at once, photos included; everyone's accounts stay (`delete-account` Edge
  Function, job **E**).

## Parental consent emails (#275)

A parent's consent for a kid is asked by email (COPPA's email plus). The address is the one on the asking parent's own
Sign in with Apple account, read when each email is sent; Foon doesn't copy it. Only when that account has no email
does the parent type one, and that address is kept on the request alone: it's cleared once the confirming email is
sent, or when the request is refused, cancelled or lapses, and goes with the request when it's deleted. A SHA-256 hash of
the address email 1 went to is kept on the request until it ends, so email 2 goes only there. Only SHA-256
hashes of the emailed links' tokens are stored. We keep no copy of either email.

Resend, which sends them, keeps its own logs of each email (such as the recipient, subject and delivery status) for
its own period. [CHECK: Resend's log retention, and whether it can be shortened.]

## Account emails (#48)

Foon emails adults about their own account: the owner's welcome, subscription notices, and a receipt after deleting an
account or a household. Each queued email is a row in `email_outbox` with its kind, dates and ids; the address is read
from the recipient's Sign in with Apple identity when the email is sent and never copied into Foon's tables. A row
that hasn't gone within 2 days is dropped rather than sent. Rows are deleted 30 days after they're queued (job **M**),
at once with their household (job **E**), and at once when the recipient's account is deleted. A deletion receipt is
never queued: `delete-account` reads the address before deleting and sends the email once the deletion is done, and
keeps nothing. We keep no copy of any of these emails; Resend keeps its own send logs (see above).

The opt-in emails (the weekly plan email and founding-family updates) queue the same way, in the same table, with the
same 30 days. An adult's choice (`email_preferences`: on or off for each, and the wording and time of the last
opt-in) is kept while they're an adult in their household: it's deleted at once when the account is deleted, unlinked
from its profile (Delete my account does this first), removed from the household, turned into a kid's, or the
household is erased (trigger `members_forget_email_preferences`, cascade from the account). Turning one off drops
that email's waiting rows at once (`opted_out`). The text of each founding-family update (`founding_updates`: subject
and body, no personal data) is kept as the record of what was sent.

An invite an adult emails to another adult (#48 PR B, approved, not built yet) is to be sent directly and never queued:
the typed address is used for that one email and not stored anywhere in Foon.

The confirmed waitlist gets only a launch email, never founding-family updates (decided 2026-11-11); see Website and
waitlist.

| Data | Kept for | From | How it goes |
| --- | --- | --- | --- |
| Email preferences (`email_preferences`) | While they're an adult in the household | Opt-in | Trigger and cascade, at once |
| Founding-family update text (`founding_updates`) | Kept | Sent | By hand |

## Push devices

A device's push token is deleted when the person signs out or turns reminders off, when the sign-in session that
registered it ends ("Sign out everywhere", revoked), when Apple says it's no longer valid, when an account has more than
10, when the person is unlinked or removed, or when the account or household is deleted (`register_push_device`,
`unregister_push_device`, `forget_push_devices`, `members_drop_push_devices` in `20261102170000_server_push.sql` and
`20261102200000_push_car4.sql`).

## Website and waitlist

| Data | How long | Starts when | Enforced by |
| --- | --- | --- | --- |
| Pending signup: email, first name | 30 days | Last email sent (or signup, if none sent) | W |
| Confirmation link | Works 7 days; only its hash is kept | Email sent | `waitlist_confirm()` |
| Confirmed signup: email, first name | Until unsubscribe | Confirmed | `waitlist_unsubscribe()`, at once |
| Hashed network address (`waitlist_attempts`) | 1 day, so up to 2 days | Attempt | W |

> **Review:** confirmed waitlist entries have no end date other than unsubscribing. Consider deleting them a set time
> after launch.

## Internal totals

To see whether Foon is working, we run `internal.metrics()` (#36, see docs/metrics.md) from the database dashboard. It
computes weekly totals pooled across all households from the tables above, shows nothing for fewer than 5 households,
and never identifies a household. Nothing new is stored: it's computed on request, and its output isn't kept in Foon's
database.

## Data on your device

Foon's offline copy (this week's and next week's plan and lists) is erased when you sign out or your household is gone.
Calendar times, receipt photos, dinner-memory photos and shared files are never stored by Foon's servers; see the
Privacy Policy.

## Backups

Deleted data can remain in our hosting provider's backups for up to 7 days, and is then gone. Backups are only used to
restore the service after a failure.

## Not kept by Foon

Payment details (Apple keeps them), birthdays, phone numbers, location (apart from the household time zone), calendar
events, receipt photos, library photos shown in Dinner memories, and photos from recipe websites.

> **Review:** our providers keep their own logs (for example, Supabase sign-in and request logs, Vercel request logs,
> Resend's logs of the emails it sends) under their own retention periods. Confirm the periods and whether to list them. [CHECK]
