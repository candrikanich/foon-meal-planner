# Foon Privacy Policy

**DRAFT — pending legal review. Not yet in effect.**

Last updated: [date of publication]

Version: `privacy-draft-v2` (what changed since v1 is under Changes to this policy)

Foon is a family dinner planner. Its job is to take the weight of dinner off one person and share it with the whole
family. To do that, it has to keep some things about your family. This policy says what we keep, why, who sees it, and
how long we keep it. We've tried to keep it short and plain.

The short version:

- Foon keeps what your family adds so everyone in your household can see the same plan. Other households can't see it.
- We don't sell your data. We don't show ads. We don't track you across apps or websites.
- Allergies are only kept if a parent agrees, are never used for ads, and are never sent anywhere for AI.
- Kids can only join with a parent's invite and consent. Parents can see, change and delete what's kept about them.
- Planners and parents can export your household's data, and you can delete your account or your household from
  inside the app.
- Foon emails adults only, never kids: a few notices about your account, and two emails you can turn on (off until
  you do).

## Who we are

Foon is an app made by The Recruiting Compass LLC ("Foon", "we", "us"). We're a small company in Ohio, USA. You can
reach us at support@getfoon.com.

> **Review:** confirm whether Foon should be registered as a trade name (DBA) and how the party should be named here.

This policy covers the Foon app for iPhone, iPad and Mac, and the website at getfoon.com, including its waitlist.

## What we collect and why

Foon works by household. Almost everything below belongs to your household. It's protected so that only signed-in
members of your household can read it (see Security). We collect it to run Foon for your family. We also look at
totals across all families, which never identify a household, to see whether Foon is working: they're pooled, and
nothing is shown for fewer than 5 households.

### Your account

When you sign in with Apple, Apple gives us:

- an account ID for you,
- an email address, which can be Apple's private relay address if you chose "Hide My Email",
- your first name, if you chose to share it.

We use these to sign you in and to tell your account apart from others. We don't use your email for marketing unless
you turn on founding-family updates (below). If you invite your kid to their own account, we use your email to ask for
your consent (see Kids and parental consent).

We also email adults a few messages about their own account:

- a welcome when you create a household (not for a sample family), with how to invite your family;
- if you own the household: when a subscription or free trial starts, renews, changes plan, is refunded, can't be
  charged, has its renewal turned off or back on, and when it ends (Apple sends its own receipts for each payment);
- a receipt when you delete your account or your household, sent once the deletion is done.

They go to the email Apple gave us for your Sign in with Apple account (which can be Apple's private relay address),
read when each email is sent; we don't copy it anywhere else. Our email provider, Resend, sends them. Kids never get
email from Foon. These emails are about your account, so they have no unsubscribe link; we keep no copy of them, and a
record that one was queued or sent (its kind and date, never your address) is deleted after 30 days (see the Data
Retention Policy).

Two more emails are yours to turn on, in Foon under Family, then Email (adults only, both off until you do):

- **The weekly plan email:** when your family's week is approved, the week's dinners (each night's dish or plan, using
  your family's own names for its dishes), and a link to Foon. Never allergies, and nothing about who's home or
  who's cooking.
- **Founding-family updates:** now and then, news about Foon for founding families, including offers. This is
  marketing, and only sent if you turn it on. Each one ends with our postal address (see Contact).

Turning one on records that you agreed, when, and to which wording. These are just yours: nobody else in your household
sees whether you turned them on. Each one has an unsubscribe link (and your mail app's own unsubscribe button), or turn
it off in Foon; either way it stops at once. Your setting is deleted with your account, or when you leave or are removed
from your household; the record that you agreed is kept (see Other records). Founding-family updates go only to adults who turned them on in Foon, not to the waitlist.

If you email an invite to another adult, Foon uses the address you type only to send that one invite. Foon doesn't keep it; Resend keeps its own record of the send, as for every email.

> **Review:** account emails (#48) are built and listed here since `privacy-draft-v2` (#48 PR D), which also put the
> two opt-in wordings (`weekly-plan-email-v1`, `founding-updates-v1`) in force. Nothing is sent until
> `account_email_enabled` is turned on. Emailing an adult's invite is approved but not built yet (#48 PR B, after
> #314); the sentence above is conditional ("If you email an invite") so the policy needn't change again when it ships.

> **Review:** our hosting provider (Supabase) keeps sign-in records for the accounts it manages, which can include
> device and network details. Confirm what Supabase Auth logs and for how long, and whether to say so here. [CHECK]

### Your household

| What | Why | Who sees it | How long |
| --- | --- | --- | --- |
| Household name and emoji | To name your family in the app | Your household | While the household exists |
| Household time zone | To know when "tonight" and "last night" are | Your household | While the household exists |
| Who the owner is | Billing and household settings | Your household | While the household exists |
| Settings: rhythm, planning mix, food rules | To plan your family's way | Your household | While the household exists |

### People in your household

A parent can add a profile for each person before they install Foon. A profile has:

| What | Why | Who sees it | How long |
| --- | --- | --- | --- |
| First name and avatar | So the family knows who's who | Your household | While they're in the household* |
| Adult or kid, parent or not | Who can manage people and consent | Your household | While they're in the household* |
| Planner or member | Who can change the plan | Your household | While they're in the household* |
| Away dates, usual schedule | Who's home for dinner | Your household | While they're in the household* |
| Notification settings | How many reminders each person gets | Your household | While they're in the household* |
| Eats separately (little ones) | Left out of ratings and votes | Your household | While they're in the household* |
| Allergies | To flag dishes (see Allergies) | Your household | Until removed, account deleted or anonymized |

\* When someone is removed, their profile is anonymized 12 months later. See How long we
keep it.

Foon doesn't ask for birthdays, phone numbers, addresses or your location (apart from the household time zone). It
doesn't ask for photos of people.

If Apple's age range feature is used when a kid's account joins, Foon keeps only the age range Apple gives (for
example, "under 13"), never a birthdate. [CHECK: this is planned for #88; the field exists but isn't used yet.]

### Dinner, food and lists

| What | Why | Who sees it | How long |
| --- | --- | --- | --- |
| Meals, ingredients, sides, recipe steps | Your family's library | Your household | While the household exists |
| Meal photos a planner adds | To show the dish | Your household | Until the household is deleted** |
| Weekly plans, nights, who's home | The week's dinners | Your household | While the household exists |
| Shopping lists, items, freezer, staples | Shopping and stock | Your household | While the household exists |
| Traditions (like Taco Tuesday) | Recurring dinners | Your household | While the household exists |
| Ratings, comments, thank-yous, who cooked | After-dinner loop | Your household | While the household exists |
| Serving notes ("no onions for me") | How people like a dish | Your household | While the household exists |
| Requests, "me too"s, offers to cook | Everyone gets a say | Your household | While the household exists |
| Tonight polls and votes | Deciding tonight's dinner | Your household | 8 weeks |
| Plan activity (what changed in the plan) | So everyone sees changes | Your household | 8 weeks |
| Comments a planner hid | Planners can hide a comment | Planners, and a kid's parents | Until shown again or erased |
| Receipt lines someone corrected | So the next receipt reads right | Your household | While the household exists |
| A shopping trip in progress | To tell the family | Your household | 1 day after it ends |
| That a shopping trip finished with something bought, and when (never what, where or who) | Counting trips across families, to see how Foon is used | Your household | 13 months |

Meal photos have their location and camera details removed on your device before they're uploaded. Recipe photos from
websites aren't saved.

\*\* Replacing a photo deletes the old one, and deleting a dish removes its photo.

### Reminders and notifications

| What | Why | Who sees it | How long |
| --- | --- | --- | --- |
| Reminder log: kind, night, times, answered | Not to over-notify | Planners; a kid's parents; each person their own | 8 weeks |
| Push notifications waiting to be sent, and sent ones | To deliver reminders | Nobody in the app | 8 weeks |
| Your device's push token (from Apple) | To reach your device | Only you | Until sign-out, reminders off, or leaving |

The reminder log never holds the words of a notification. A push notification's text can include a person's first
name. It never includes allergy details.

### AI helpers

Foon's optional AI helpers use Apple's on-device model. Where your device can run it, nothing is sent anywhere for AI.

If a planner adds a dish from a photo, PDF or post on a device that can't run Apple's model, the recipe's lines (title,
servings, ingredients and steps) and its source link are held on our servers so a planner's device in your family that
can run the model tidies them up. The lines are emptied once that's done, or after 3 days at most (checked hourly).
The job's copy of the tidied recipe is deleted after 30 days. Allergies and information about people are never part
of this.

### Subscriptions

If your household subscribes, Apple tells us about it. We keep Apple's original transaction ID, which plan, its
status, when it ends, whether it renews, and whether it's a test or real purchase. We keep the notices Apple sends about
it for 2 years. We never keep your name, card, price paid or other payment details: Apple keeps those. Members of the
household can see its subscription status.

### Other records

- **Consent records.** When a parent agrees to keep allergies, or to invite a kid, we record who agreed, when, and which
  wording they saw; for a kid, also how they consented (by email) and when the confirming email went out. Each
  request for a kid's consent (its status and times) is kept until 30 days after it ends. These stay with the household even if the parent who agreed later deletes their account, so we can
  show the consent was given. They're deleted when the household is, and a kid's parental consent record is deleted
  when a parent deletes everything about that kid.
- **Agreement records.** Which version of the Terms, this policy, or an email's wording you agreed to, when, and where
  in the app. Kept after your account is deleted, as proof of what you agreed to, with nothing else about you. Deleted
  with the rest of a kid's information when a parent deletes everything about them.
- **Invites.** An invite records who it's for, who made it, and when it was used. Only a scrambled form of the code is
  stored. Invites are deleted 30 days after they expire, are used or are cancelled.
- **Safety counters.** To stop someone guessing invite codes, we record each attempt to use a code, wrong or right,
  for 1 day. To keep the recipe importer fair, we count how many links each account reads a day, and delete those
  counts after 7 days.

> **Review:** we don't currently use analytics or crash reporting in the app. If we add them (#28), this policy, the App
> Store privacy label, and "no tracking" all need another look first.

## Kids and parental consent

Foon is a household app that parents run. It isn't in the App Store's Kids category, and it's not made for kids to use
alone.

### Children under 13

Foon knowingly collects information from children under 13, through accounts a parent invites. We treat every kid
account as a child's account under the Children's Online Privacy Protection Act (COPPA).

| What a kid's account generates | Why | Who receives it |
| --- | --- | --- |
| Apple account ID and email (from Sign in with Apple; can be Apple's relay address), and first name if Apple shares it | Signing in | Foon; Supabase, our host |
| First name, avatar, schedule (a parent enters these) | Who's home | Their household; Supabase |
| Allergies (a parent enters these) | Flagging dishes | Their household; Supabase |
| Ratings, comments, thank-yous, serving notes, requests, votes, list items they add | Taking part in family dinner | Their household; Supabase |
| Their device's push token | Reminders | Apple, to deliver them; Supabase |
| Reminders sent to them | Not over-notifying | Planners and parents in their household; Supabase |
| Network address in our provider's request logs | Running the service | Supabase [CHECK: period] |

- **No disclosure.** We don't disclose a child's information to anyone except the service providers that run Foon for
  us (see Who we share with), who may use it only to provide their service. We don't sell it, use it for ads, or let
  anyone else collect it through Foon.
- **A parent's rights.** A parent can, at any time:
  - **review** what's kept about their child: it's in the app, and Family → Your data → Export saves it as a file
    (apart from the kid's sign-in details, their device's push token, and pushes still waiting to be sent). They can
    also ask us at support@getfoon.com;
  - **have it deleted:** on the kid's profile, Delete everything about them deletes it all at once, sign-in account
    included (see below). They can also ask us at support@getfoon.com;
  - **refuse further collection:** withdraw consent on the kid's profile, which stops the kid's account at once.

  The details are below.

- **How long we keep it.** Our [Data Retention Policy](retention.md) is part of this notice. Its section "Kids:
  purposes and periods" is our written retention policy for children's information: why we keep each kind, the need
  for it, and when it's deleted.

- **Accounts.** Foon is set up by an adult. A kid gets their own account only when a parent invites them, and only
  after that parent has given verifiable consent by email (COPPA's "email plus", 312.5(b)(2)(viii)):
  - When a parent asks to invite a kid, we email them a notice: what we'd keep about the kid, who receives it, that
    nothing is collected from the kid without their consent, and a link to agree. It goes to the address on that
    parent's own Sign in with Apple account. If there isn't one, the parent can type an address, which we email to
    confirm it's theirs; we keep that
    address only until our confirming email is sent or the request ends.
  - The parent opens the link and agrees on getfoon.com (or says no). We then send a second email confirming the
    consent, with a link to withdraw it. The consent counts only once that second email has gone out.
  - The link in the first email works for 7 days; the withdraw link in the second, 30 days. Withdrawing in the app
    always works.
  - We record which parent agreed, when they agreed, when the confirming email went out, how they consented, and the
    wording they saw. We keep no copy of either email.

> **Review:** today the app doesn't check the age of someone who signs up and creates a household; a kid's account
> is only marked as a kid by the parent who invites them. Apple's age range check is planned (#88). Confirm this is
> enough, given the Terms say account holders must be 18 or older. [CHECK]
- **Profiles without accounts.** A parent can add a kid's profile (first name, avatar, schedule, allergies) without the
  kid having an account. The kid can take part by "passing the phone".
- **What we keep about a kid.** The same things as for anyone in the household, listed above: first name, avatar,
  whether they're home, their schedule, allergies a parent adds, and what they add themselves, such as ratings,
  comments, requests, votes, serving notes and list items. We don't collect a kid's email for marketing, and we don't
  email kids.
- **What a parent can see.** Most of what's kept about a kid is visible to everyone in the household, including the
  parent: the profile, allergies, ratings, comments, requests and votes. A kid's reminder log and any of their comments
  a planner hid are visible to the kid's parents and to planners. Every parent can export the household, planner or
  not: a parent who isn't a planner gets what they can see, including their kids' reminder log and hidden comments,
  but not another adult's.
- **What a parent can change or delete.** Parents can change a kid's profile and allergies, remove allergies at any
  time, remove the kid from the household, and delete everything about them. A planner can hide a kid's comment. A
  parent can export the household's data, and the owner can delete the household.
- **Withdrawing consent.** A parent can withdraw consent on the kid's profile at any time. The kid's account is unlinked
  at once and loses access to the household. If consent isn't given again within 30 days, what the kid entered
  themselves is deleted: their own ratings, comments, thank-yous, serving notes, requests and "me too"s, offers to
  cook, poll votes, plan changes, and their age range. Shopping list lines stay on the family's list, but no longer
  show the kid marked or ticked them. What a parent entered for them stays while they're in the family.

> **Review:** a list line records no author and is shared by everyone who added that item, so a withdrawn kid's lines
> stay on the family's list and only stop naming the kid (#286). Confirm that's enough under COPPA 312.10.
- **Removing a kid.** Their account is unlinked at once and loses access to the household. 12 months later their
  profile becomes "Former member": the name, avatar, schedule, allergies, serving notes and comments go, and their
  ratings stay as anonymous history.
- **Deleting a kid's own account.** Their account, sign-in included, is deleted, along with their comments, poll
  votes, serving notes and notes on requests they wrote themselves. The profile a parent made stays.
- **Deleting everything about a kid.** Any parent, on the kid's profile, at any time. It happens at once, not after a
  wait, and can't be undone. Deleted: the kid's profile (name, avatar, schedule), allergies, ratings and comments,
  thank-yous they sent and the ones sent to them for a dinner they cooked, serving notes about them or written by them,
  requests and "me too"s, offers to cook, attendance, poll votes, plan changes, the reminder log, push devices and
  pushes for or about them, invites, the parental consent record, and their sign-in account (Apple account ID and
  email). Kept, without their name: the family's plans, dishes, dinners and shopping list lines. List lines don't
  record who added them (one line holds everyone's adds), so a line they added stays on the list, and it stops saying
  they checked it off or marked it for tonight. A rating, request or note they entered for someone else stays that
  person's, without saying who entered it.

To ask about or delete your child's information, a parent can also write to support@getfoon.com.

> **Review:** COPPA. The consent method is email plus (decided 2026-11-08, #275), which 312.5(b)(2)(viii) allows only
> to an operator that doesn't disclose a child's information. Confirm that household members seeing a kid's name and
> comments isn't "disclosure" (compliance-check.md decision 2), and what the fallback would be if it is. [CHECK]
> Confirm the direct notice (email 1) meets 312.4(c)(1), and that this section and the retention policy
> (retention.md) meet the rest of the notice requirements. Consents given in the app before #275 no longer count
> since #277 put the email-plus wording in force: those kids are signed out (nothing erased) until a parent agrees
> again by email.

> **Review:** a kid's ratings are kept as anonymous history after they're removed. Erasing a withdrawn kid's own ratings
> is a hard delete. Confirm both are acceptable.

## Allergies

Allergies can be health information. We treat them carefully.

- **Opt-in.** Foon keeps allergies only after a parent reads this and taps Agree and save:

  > Foon keeps these so it can flag dishes. Only your household and our hosting provider, which stores them for us,
  > receive them. They're never sold, never used for ads, and never leave your devices for AI. A parent can withdraw
  > anytime in Family → Allergy alerts, which erases them all.

  We record who agreed, when, and which wording they saw. The server refuses to store an allergy without that consent.
  When this wording changes in a way that matters, a parent is asked again (see Changes to this policy).
- **What's kept.** For each person: which of the 9 major US allergens apply, plus any others a parent types in, or an adult types
  in for themselves.
- **Who sees them.** Everyone in your household, so the whole family can see why a dish is flagged. Parents can add
  or change anyone's, and an adult can add and remove their own. Other households can't see them. Our hosting
  provider stores them for us and does nothing else with them.
- **What they're for.** Flagging dishes and shopping items. That's all.
- **Never for AI, never for ads.** Allergies are never sent anywhere for AI, never sold, and never used for advertising.
  They're never in a notification's text.
- **Withdrawing.** A parent can remove anyone's allergies at any time, and an adult can remove their own on their
  profile, one at a time or all at once. A parent can also turn allergy alerts off for the household, which
  withdraws consent and erases all of the household's allergy data at once, including the allergy notes on shopping
  lists.

Allergy flags are a helper, not a guarantee. Always check labels. See our Terms of Use.

Allergies may be consumer health data under some state laws. Our [Consumer Health Data Privacy
Policy](consumer-health-data.md) covers them in full.

> **Review:** confirm the opt-in sentence and its consent record are enough consent under Washington's, Nevada's and
> Connecticut's laws (see compliance-check.md). Since #280 (`allergy-data-v2`) it names who receives allergies and how
> to withdraw. Households that agreed to v1, which named neither, are asked again since #277 (Chris reversed the
> 2026-11-07 decision on 2026-11-09): their allergies keep flagging and nobody adds one until a parent agrees to v2.

## What stays on your device

Some things Foon reads only on your device. It never sends or saves them on our servers:

- **Calendar.** If a planner turns on Spot busy evenings, Foon reads the times of that device's calendar events to
  suggest rushed nights. It doesn't keep them.
- **Receipt photos.** Read on the device, never kept or uploaded. Only lines someone corrects are kept.
- **Dinner memories.** If you turn it on, Foon shows photos from your library taken around dinner time. It never
  saves or uploads them.
- **Photos, PDFs and screenshots you share to Foon.** Read on the device and then deleted. Only the text you keep leaves
  the device (and, as above, a recipe's lines when your device can't tidy them itself).
- **Offline copy.** This week's and next week's plan and your lists, so they work in the store. It's erased when you
  sign out or your household is gone.
- **Tips.** Which tips you've seen.

## Who we share with

We don't sell or share your information with anyone for their own use. We use a few service providers to run Foon.
They handle data for us, only to provide their service, and each is bound to protect it at least as strongly as this
policy does. [CHECK: data processing agreements on file.]

| Provider | What they do for Foon | What they handle |
| --- | --- | --- |
| Supabase | Database, sign-in, photo storage, server functions | Everything Foon keeps on its servers |
| Apple | Sign in with Apple, push notifications, App Store payments | Sign-in, push tokens and text, subscriptions |
| Resend | Sends waitlist emails, parental consent emails, account emails to adults, and an invite an adult chooses to email | Waitlist email addresses and names; a parent's email address and their kid's first name, in consent emails; an adult's email address in account emails (no names; the weekly plan email carries the family's dish names); the address typed for an emailed invite, used only for that email. Resend keeps its own logs of each email sent [CHECK: period] |
| Vercel | Hosts the getfoon.com website | Website requests |

Our servers are in the United States (Supabase's us-east-1 region, AWS, N. Virginia).

When you import a recipe from a link, our server opens that web page to read the recipe. The website sees a request
from our server. We send it nothing about you.

We may also share information if the law requires it, to protect someone's safety, or as part of a sale or merger of
the business, in which case this policy would still apply to what we have.

> **Review:** confirm the legal-request and business-transfer sentence, and whether we need data processing agreements
> on file with each provider (Supabase, Resend and Vercel offer them).

> **Review:** Supabase and Vercel keep standard request logs (including network addresses) for a limited time. Confirm
> their periods and whether to list them here. [CHECK]

## No sale, no ads, no tracking

- We don't sell personal information, and we don't "share" it for targeted advertising.
- The app has no ads and no advertising tools.
- The app doesn't track you across other companies' apps or websites, so it doesn't ask for Apple's tracking permission.
- The website has no ads and no tracking scripts, and sets no cookies.

## How long we keep it

Most of what your family adds is kept while your household exists, because it's your family's history. Some things are
deleted sooner:

- tonight polls, plan activity, and the reminder log: 8 weeks;
- a shopping trip's "heading to the store": 1 day after it ends;
- recipe lines waiting for a family device: 3 days at most; the tidied result: 30 days;
- invites: 30 days after they expire, are used or are cancelled;
- a record of an account email (its kind and dates, never your address): 30 days;
- that a shopping trip finished, and when: 13 months;
- subscription notices from Apple: 2 years;
- which wording of the Terms, this policy or an email you agreed to: kept after your account is deleted, as proof;
- a removed person's profile: anonymized 12 months after they're removed;
- what a kid entered themselves: 30 days after a parent withdraws consent;
- a request for a parent's consent: 30 days after it ends; an email address a parent typed for it, once our
  confirming email is sent or the request ends.

Deleted data can remain in our hosting provider's backups for up to 7 days, and is then gone.

The full list, with every period and what starts it, is in our [Data Retention Policy](retention.md), which is part
of this policy.

## Deleting and exporting

- **Remove an allergy.** Parents, on the person's profile, at any time. An adult can also remove all of their own.
- **Remove someone.** Parents, on the person's profile. Their account loses access at once.
- **Delete everything about a kid.** Parents, on the kid's profile: the kid's information and sign-in account are
  deleted at once (see Kids).
- **Delete your account.** Anyone, in Family → Your data (or on the first screen before you've joined a household).
  You confirm with Apple, and we revoke Foon's Sign in with Apple access. Then:
  - if you're the owner, your household and everything in it is erased, photos included (handing ownership to
    another parent first is planned but not available yet);
  - if you're another adult, your profile becomes "Former member": your allergies, settings, schedule, serving notes,
    comments and the notes on your requests are deleted, and your ratings and cooking history stay without your name;
  - if you're a kid, your account is deleted, sign-in included, along with what you wrote yourself; your profile and
    ratings stay in the family, managed by your parents (see Kids).
- **Delete your household.** The owner, in Family → Your data. Everything is erased at once for everyone, photos
  included. Everyone's own account stays.
- **Export.** Planners and parents can export the household as a file: meals, plans, lists, members, allergies,
  consent records and more. Account IDs and invite codes are left out. The file holds what the person exporting can
  see: a parent who isn't a planner gets their kids' reminder log and hidden comments, not other adults'.

If you can't use the app, write to support@getfoon.com.

## Security

- Every household's data is walled off in the database: the server checks each request and only returns rows for a
  household you belong to. Some data, like hidden comments, is limited to planners and, for a kid's, their parents.
- Photos are stored privately, in a folder for your household, and shown through links that expire after 15 minutes.
- Everything between the app and our servers is encrypted in transit (HTTPS).
- "Sign out everywhere" ends every session at once.
- Invite codes work once, expire after 7 days, and lock after 5 wrong guesses in 15 minutes.

No system is perfectly secure. If we learn of a breach that affects you, we'll tell you as the law requires.

> **Review:** confirm whether to describe encryption at rest (Supabase encrypts stored data) and our breach-notice
> duties by state.

## Your rights

Depending on where you live, US state privacy laws may give you the right to:

- know what personal information we have about you, and get a copy;
- correct it;
- delete it;
- opt out of the sale of your information or its use for targeted advertising (we don't do either);
- limit the use of sensitive information (we use allergies only to flag dishes);
- appeal if we say no.

Most of this you can do yourself in the app: see Deleting and exporting. You can also ask us at support@getfoon.com.
We'll check that the request comes from you (or from a parent, for a kid) before we act on it. You can use an
authorized agent where the law allows it.

- **How fast.** We'll answer within 45 days. If we need longer, we'll tell you why within those 45 days and take at
  most 45 more.
- **Cost.** Requests are free, up to twice a year.
- **Appeals.** If we say no, you can appeal by replying to our answer or writing to support@getfoon.com with "Appeal"
  in the subject. We'll answer in writing within 45 days. If we still say no, you can contact your state's attorney
  general. [CHECK: attorney general contacts]

We won't treat you differently for using these rights.

> **Review:** compliance-check.md finds the general state privacy laws' thresholds aren't met, apart from
> Connecticut's sensitive-data rule (from 2026-07-01, UNVERIFIED), and that no California notice is needed yet.
> Confirm.

## The website and the waitlist

- The website has no ads and no tracking scripts, and sets no cookies.
- The waitlist is for adults. If you join, we keep your email address and, if you give it, your first name.
- We use them to email you a link to confirm your spot (that email also tells you about the founding-family offer),
  and to tell you when Foon opens. That's all: the waitlist doesn't get founding-family updates or other news.
- The confirmation link works for 7 days. Until you confirm, your signup is pending, and we delete it 30 days after the
  last email we sent for it.
- After you confirm, we keep your email and name until you unsubscribe. Every email has an unsubscribe link, and
  unsubscribing deletes your email and name right away.
- To limit abuse, the form keeps your network address for up to 2 days, as a keyed hash, not as the address.
- Waitlist emails are sent through Resend, and the list is stored with Supabase.
- The consent pages (getfoon.com/consent) are where a parent agrees to, refuses or withdraws consent for their kid,
  from the link in our email. They send the link's code to Foon and nothing else, and set no cookies.

> **Review:** after launch, should confirmed waitlist entries be deleted after a set time even without unsubscribing?

## Changes to this policy

If we change this policy, we'll update the date at the top and post the new version at getfoon.com/privacy. If a
change is significant, we'll tell you in the app before it takes effect. If a change affects how we use kids'
information, we'll ask parents to consent again first.

Every agreement records the wording it was given to. When we change wording you agreed to, Foon asks again: adults see
the new Terms and Privacy Policy in the app before going on; a household can't add allergies until a parent agrees to
the new allergy wording (the ones already recorded keep flagging dishes); and a kid whose parent agreed to older wording
is signed out, with nothing deleted, until a parent agrees again from the email we send every parent with a verified
email (with one reminder a week later).

> **Review:** asking again is built (#277). Confirm the mechanism meets the amended COPPA rule for material changes,
> and that the app's prompt counts as telling people before a significant change takes effect.

### What changed

- **v2** (`privacy-draft-v2`, #48): lists the emails Foon sends adults (welcome, subscription notices, deletion
  receipts), the two emails you can turn on (the weekly plan email and founding-family updates), what an emailed
  invite keeps (Foon keeps nothing), that the waitlist gets only its confirmation and a launch email, that Foon counts finished
  shopping trips (never what, where or who) for 13 months, that a record of each account email goes after 30 days,
  and that the record of what you agreed to is kept after your account is deleted.
  Every adult is asked to agree again in the app. Nothing about kids' information changed.
- **v1** (`privacy-draft-v1`, #277): the first version adults agree to in the app.

## Contact

The Recruiting Compass LLC
34125 Center Ridge Road #1012
North Ridgeville, OH 44039
support@getfoon.com

> **Review:** COPPA's notice lists the operator's address, phone and email (312.4(d)(1)). The address is set (a
> mailbox, also in every waitlist email's footer for CAN-SPAM). Still open: whether to give a phone.
