# Foon QA

Foon QA is the staging build as an app of its own, so one phone can hold both: Foon for the family (production) and
Foon QA for testing (hosted staging). They have different bundle IDs, App Groups, icons, URL schemes and invite links,
and they never share data: each talks to its own Supabase project and keeps its own sign-in.

| | Foon | Foon QA |
| --- | --- | --- |
| Build configuration | Release (`Foon Prod` scheme); Debug from Xcode | Staging (`Foon` scheme's archive) |
| Supabase | production (Debug: local) | hosted staging |
| Bundle ID | `com.andrikanich.foon` | `com.andrikanich.foon.qa` |
| Extensions | `.share`, `.dinner`, `.widget` | `.qa.share`, `.qa.dinner`, `.qa.widget` |
| App Group | `group.com.andrikanich.foon` | `group.com.andrikanich.foon.qa` |
| Home screen | "Foon", `AppIcon` | "Foon QA", `AppIcon-QA` (a blue QA band) |
| URL scheme | `foon://` | `foonqa://` |
| Invite link | `https://www.getfoon.com/invite?code=…` | `https://www.getfoon.com/qa/invite?code=…` (emailed ones: staging's `INVITE_PATH`) |
| Push topic | `com.andrikanich.foon` | `com.andrikanich.foon.qa` (staging's `APNS_TOPIC`) |
| Xcode Cloud tag | `beta/*` | `testflight/*` |
| TestFlight | Foon → External "Family" (then the App Store) | Foon QA → Internal only, never submitted |

## How it's built

`project.yml` sets `FOON_APP_ID`, `FOON_APP_NAME`, `FOON_APP_GROUP`, `FOON_APP_ICON`, `FOON_URL_SCHEME` and
`FOON_INVITE_PATH` for every config, with Foon QA's values for Staging only. Bundle IDs, the display name, the icon, the
URL scheme and the App Group entitlement come from them, and the Info.plist keys `FoonAppGroup`, `FoonURLScheme` and
`FoonInvitePath` hand them to the code (`AppGroup.id`, `InviteCode.Links.current`), so nothing in Swift names an
environment. The Mac build follows the same settings (a Staging Mac build is Foon QA too); Xcode Cloud doesn't build the
Mac app, and the Mac has no App Group.

Left the same in both apps, because nothing ties them to the app's identity: the background refresh identifiers
(`com.andrikanich.foon.answers`, `.ai`; Apple doesn't require them to start with the bundle ID, and each app schedules
its own), the widget kind (scoped to its own extension), and logger subsystems and queue labels.

`ci_scripts/ci_post_clone.sh` checks after `xcodegen` that the scheme's archive config builds the expected bundle ID
(`Foon` → `com.andrikanich.foon.qa`, `Foon Prod` → `com.andrikanich.foon`), so a QA build can't reach the family's
TestFlight as Foon. The QA icon is drawn by `scripts/make-qa-icon.py` from `AppIcon`: rerun it when the icon changes.

**Invite links.** getfoon.com's association file gives `/invite` to Foon and `/qa/invite` to Foon QA, so a phone with
both opens each invite in the app that made it. Without Foon QA, a QA link lands on `/qa/invite`, which says it's the
test app. The app builds the link it shares; an emailed invite's link is built by the `account-email` function, which
uses `/qa/invite` when the project's `INVITE_PATH` secret says so (staging). Either app reads either path: a code made on staging fails to redeem in Foon anyway (and the other way
round), since each server only knows its own codes. The custom scheme is per app: Foon reads only `foon://invite/…`,
Foon QA only `foonqa://invite/…`.

## Promote to family

A Foon QA build that passed testing goes to the family on the same commit: run **Actions → Promote to family → Run
workflow** (`promote-to-family.yml`). Leave the tag empty for the newest `testflight/*` tag, or name one. It:

1. refuses a commit that isn't on main;
2. refuses unless production already has the commit's backend: the commit is in the newest `Deploy production` run that
   applied migrations, or nothing under `supabase/` changed between that run and the commit (an app-only change);
3. refuses if a `beta/*` tag already points at the commit;
4. tags it `beta/<UTC date>` (`-2`, `-3` … when the date is taken), pushes the tag, and writes the tag, commit and
   source tag in the run's summary.

Xcode Cloud's production workflow then builds Foon from the `beta/*` tag. A tag pushed with the workflow's
`GITHUB_TOKEN` starts no other GitHub workflow, but Xcode Cloud is a GitHub App with its own webhook, so it does see it.

Tagging by hand (`git tag beta/<date> <commit>`, then push) still works; the workflow only adds the checks.

## Things to know

- **Separate sign-ins and data.** Foon QA starts signed out. Signing in with the same Apple ID finds the same staging
  account and household, provided Sign in with Apple on the QA App ID is grouped with Foon's (below): grouped apps get the
  same Apple user ID, which is what Supabase matches. Without the grouping, Foon QA would be a new staging user.
- **The first install.** Until Foon QA is in TestFlight, the newest build in Foon's app record decides what's on the
  phone: installing a `beta/*` build replaces a staging build of Foon with production Foon. Staging's data stays on
  staging and shows up in Foon QA after signing in.
- **Subscriptions in Foon QA's TestFlight builds.** In-app products belong to an app's App Store Connect record, so a
  Foon QA TestFlight build finds nothing to buy until the products (subscriptions.md → Products) are created in Foon
  QA's record too, with its own server notification URLs pointing at staging. Apple's
  [In-App Purchase information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information)
  says a product ID is unique within an app, so the same IDs should work there; that's untested. Runs from Xcode still
  buy from `Foon/Foon.storekit`. The `app-store-notifications` function also checks for Foon's bundle ID only, so it
  would refuse Foon QA's notifications. Not set up yet: decide whether subscription testing on staging needs it.
- **Push** on staging needs `APNS_TOPIC=com.andrikanich.foon.qa`. Without it, APNs refuses every staging push with
  `DeviceTokenNotForTopic`, and `send-push` forgets the device as dead. Once it's set, the same happens to devices still
  registered by older staging builds of Foon: they're forgotten, and Foon QA registers its own.
- **Delete my account** on staging exchanges the app's Sign in with Apple code, so staging's `APPLE_CLIENT_ID` must
  match the app that signed in. Set it to `com.andrikanich.foon.qa` only once Foon QA is on the phone (step 13): before
  that, staging builds of Foon would get `apple_revoke_failed` and couldn't delete an account at all. Afterwards, a
  Staging-pointed build signed as Foon (an older QA build, or Debug from Xcode against hosted staging) has the same
  problem.
- **Emailed invites** on staging need `INVITE_PATH=/qa/invite`, or they open Foon instead of Foon QA.

## Foon QA setup (one time, Chris)

In this order; Xcode Cloud can't build Foon QA until the App IDs and the App Store Connect app exist.

**Apple Developer (developer.apple.com → Certificates, Identifiers & Profiles):**

1. Identifiers → + → App Groups → Continue: description "Foon QA", identifier `group.com.andrikanich.foon.qa` →
   Continue → Register.
2. Identifiers → + → App IDs → App → Continue: description "Foon QA", Explicit bundle ID `com.andrikanich.foon.qa`.
   Capabilities:
   - App Groups;
   - Associated Domains;
   - Push Notifications (no certificates: the existing "Foon" key's token auth covers every app in the team);
   - Sign in with Apple → Edit → **Group with an existing primary App ID** → `com.andrikanich.foon` → Save;
   - Declared Age Range.

   Continue → Register. Then open the new App ID → App Groups → Configure → tick `group.com.andrikanich.foon.qa` →
   Continue → Save.
3. Repeat + → App IDs → App for each extension, with App Groups ticked and configured to `group.com.andrikanich.foon.qa`:
   `com.andrikanich.foon.qa.share` ("Foon QA Share"), `com.andrikanich.foon.qa.dinner` ("Foon QA Dinner"),
   `com.andrikanich.foon.qa.widget` ("Foon QA Widget").

**App Store Connect:**

4. Apps → + → New App: iOS, name "Foon QA" (it must be unique on the App Store; "Foon QA Test" if taken), language
   English (U.S.), bundle ID `com.andrikanich.foon.qa`, SKU `foon-qa`, access Full. It's never submitted.
5. Foon QA → TestFlight → Internal Testing → + : a group (e.g. "QA") with yourself and any other testers.
6. Foon → TestFlight: leave yourself in the External "Family" group only, so Foon on your phone is always the production
   build.

**Supabase, staging project (`cbftcssbnfdjjxoeflvj`) only:**

7. Authentication → Sign In / Providers → Apple → Client IDs: `com.andrikanich.foon,com.andrikanich.foon.qa` (keep Foon's
   for Xcode runs of Debug against a hosted project and for older staging builds) → Save.
8. Edge Functions → Secrets: nothing yet. These switch staging over to Foon QA, so they wait for step 13.

**Xcode Cloud** (see below for why it's a new product):

9. Locally: in `project.yml`, temporarily set the Foon target's `PRODUCT_BUNDLE_IDENTIFIER` to `com.andrikanich.foon.qa`
   (Apple's step for bundle IDs set by build settings), `xcodegen generate`, open the project, Product → Scheme → `Foon`.
10. Report navigator → Cloud → create a workflow; when Xcode lists products, pick the one for `com.andrikanich.foon.qa`
   and the "Foon QA" app record. Workflow: scheme `Foon`, start condition Tag Changes `testflight/*`, environment
   `SUPABASE_URL` and `SUPABASE_ANON_KEY` (staging's, as on the old QA workflow), archive iOS, post-action TestFlight
   Internal Testing → the Foon QA group. Save, then revert `project.yml` (don't commit the change).
11. Check in App Store Connect that Foon still lists its "Production beta" workflow (`beta/*`). Then, in Foon → Xcode
   Cloud → Manage Workflows, delete Foon's old QA workflow (`testflight/*`), or its next tag builds Foon QA under Foon and
   the upload fails.
12. Push a `testflight/*` tag and check the build lands in Foon QA's TestFlight with the QA icon.

**Supabase, staging, once Foon QA is installed:**

13. Edge Functions → Secrets: add `APNS_TOPIC` = `com.andrikanich.foon.qa` and `INVITE_PATH` = `/qa/invite`, and set
   `APPLE_CLIENT_ID` = `com.andrikanich.foon.qa` (delete-account's token revoke). Production leaves `APNS_TOPIC` and
   `INVITE_PATH` unset and keeps `APPLE_CLIENT_ID` = `com.andrikanich.foon`. A mistyped `INVITE_PATH` falls back to
   `/invite` and logs a warning.

## Xcode Cloud: one product per bundle ID

Foon QA needs its own Xcode Cloud product; an existing workflow of Foon's can't upload it to a different app. Apple's
[Configuring your first Xcode Cloud workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow)
(read 2026-11-11):

> If your project contains targets that use the same bundle identifier, Xcode Cloud treats them as one product. Note
> that a product can only have one bundle ID, and a bundle ID always matches exactly one Xcode Cloud product.

and

> If you use `.xcconfig` files to set the bundle identifier or use them to automatically change the bundle identifier,
> you need to take extra steps to start using Xcode Cloud. First, set the bundle identifier for your app target in the
> Signing & Capabilities pane of your project or workspace. Then configure your first workflow as described below.
> Repeat this process for each bundle identifier. Note that you need to use App Store Connect to view your workflows and
> builds because Xcode relies on the explicitly set bundle identifier to show them.

Products are made only in Xcode (the App Store Connect API can read and delete them, not create them), and workflows
of a product are edited in App Store Connect afterwards.

**Known risk.** Apple Developer Forums thread
[Xcode Cloud reassigns one ciProduct between app targets with unique bundle IDs](https://developer.apple.com/forums/thread/839723)
(July–November 2026) reports that onboarding a second bundle ID from the same target, through build configurations as
here, can move the existing product to the new app instead of making a second one, so Foon's workflows show up under
Foon QA. Apple's suggested workaround there is to restart Xcode before onboarding the second product and to use the
latest Xcode; posters also report success with Product → Scheme set first, or with the legacy onboarding
(`defaults write com.apple.dt.Xcode XcodeCloudEnableNewOnboarding -bool NO`). Before step 10, note Foon's workflows
(screenshots of each: start conditions, environment variables, post-actions); after it, do step 11's check. If Foon's
product moved, recreate its "Production beta" workflow from the notes before the next `beta/*` tag.
