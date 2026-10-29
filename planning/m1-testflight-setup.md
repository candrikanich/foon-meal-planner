# #37 TestFlight alpha: what Chris needs to do

Goal: Foon on our family's phones through internal TestFlight, against a hosted Supabase project.
Your part is about an hour, almost all of it in web dashboards. I do the code side (bottom of this page).

## Already in place
- Bundle ID `com.andrikanich.foon`, Apple team `G374A783RH` (TRC). The app has the Sign in with Apple entitlement.
- Build configs: Debug (local Supabase), **Staging** (hosted staging), Release (prod). The Staging and Prod xcconfigs read the URL and key from gitignored `*.local.xcconfig` files, so a hosted build can't ship without them.
- The `delete-account` Edge Function already reads `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_CLIENT_ID` and `APPLE_PRIVATE_KEY`. It uses them to revoke Apple sign-in when someone deletes their account (an App Store requirement).

## Your steps

### 1. Supabase: create the hosted project (10 min) — done 2026-10-29
Project `cbftcssbnfdjjxoeflvj` (URL `https://cbftcssbnfdjjxoeflvj.supabase.co`), us-east-1, in the Foon org
`wxaodzxjkzimkvienaug`. The GitHub secrets are set. `deploy-staging.yml` refuses any other ref, because the same
Supabase account also holds the TRC databases. Still to do: rename the project from its default name to `foon-staging`
(cosmetic).

1. On supabase.com, create a project named `foon-staging`, in a US East region.
2. Save the database password in your password manager.
3. Send me these from Project Settings:
   - the **project ref** (the ID in the URL);
   - the **Project URL**;
   - the **anon / publishable key**. It's safe in the app; RLS protects the data.
4. Create a personal **access token** at Account → Access Tokens.
5. In GitHub (repo Settings → Secrets → Actions), add:
   - `SUPABASE_ACCESS_TOKEN`
   - `SUPABASE_DB_PASSWORD`
   - `SUPABASE_PROJECT_REF`

   These let CI apply migrations and deploy Edge Functions. Nobody runs `db push` from a laptop.

One project for the alpha is enough. Prod gets its own project before external testers or launch.

### 2. Apple Developer: Sign in with Apple key (10 min)
1. In developer.apple.com, open Identifiers → `com.andrikanich.foon`. Confirm that **Sign in with Apple** is ticked, and tick **Push Notifications** while you're there (car 6 needs it).
2. In Keys, choose **+** and create a key named "Foon".
   - Enable **Sign in with Apple** and configure it with `com.andrikanich.foon` as the primary App ID.
   - Also enable **Apple Push Notifications service**, so one key covers car 6 too.
3. Download the `.p8` file. You can only download it once, so store it in your password manager. Note the **Key ID**.
4. In Supabase, set the Edge Function secrets. Do this yourself so the private key never passes through me:
   - either in the dashboard (Edge Functions → Secrets),
   - or with `supabase secrets set --project-ref <ref> APPLE_TEAM_ID=G374A783RH APPLE_KEY_ID=<key id> APPLE_CLIENT_ID=com.andrikanich.foon APPLE_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)"`
5. In Supabase, open Authentication → Sign In / Providers → **Apple**. Turn it on and set Client IDs to `com.andrikanich.foon`. Leave the secret empty: native sign-in doesn't need it.

### 3. App Store Connect: app record and testers (10 min)
1. Choose My Apps → **+** → New App.
   - Platforms: iOS (and macOS if you want the Mac app in TestFlight too).
   - Name: Foon. Bundle ID: `com.andrikanich.foon`. SKU: anything, such as `foon`.
2. In TestFlight → Internal Testing, create a group named "Family".
3. Internal testers have to be **users on the TRC App Store Connect team**.
   - Add each family adult under Users and Access, with a minimal role (Customer Support or Developer), and add them to the group.
   - Anyone who shouldn't be on the team needs **external** testing. That needs a one-time Beta App Review and a privacy policy URL (#67), so I'd keep the alpha internal.

### 4. Xcode Cloud: automatic builds (15 min, needs your Apple ID in Xcode)
1. Open `Foon.xcodeproj` and go to Product → Xcode Cloud → Create Workflow. Grant access to the GitHub repo `candrikanich/foon-meal-planner`.
2. Workflow settings:
   - Start condition: **branch changes on `main`**.
   - Action: **Archive**, iOS, scheme `Foon`, configuration **Staging**.
   - Post-action: **TestFlight Internal Testing**, group "Family".
   - Xcode version: **latest beta**, which matches what we build with.
3. Under Environment → Variables, add:
   - `SUPABASE_URL`, the Project URL from step 1;
   - `SUPABASE_ANON_KEY`, the publishable key from step 1.

   My `ci_post_clone.sh` writes them into `Staging.local.xcconfig` at build time.

Xcode Cloud numbers builds automatically, and 25 compute hours a month are free, which covers this easily.

### 5. Two decisions
- **Founding flag:** my recommendation is a server setting, "founding open", that is on now and you switch off at launch. Every household created while it's on gets `founding = true`. The alternative is a fixed cutoff date.
- **Crash reporting for the alpha:** my recommendation is TestFlight's built-in crash reports and feedback (Xcode → Organizer), which are free and need no account. Sentry (#28) can wait until external testing, so you don't need to make the Sentry account yet.

## My side (once you send the step 1 values)
- `deploy-staging.yml` (done): applies migrations and the starter catalog to staging and deploys Edge Functions on merge to `main`, using the step 1 secrets.
- `ci_scripts/ci_post_clone.sh` (done): writes `Staging.local.xcconfig` from the Xcode Cloud variables and generates the project with XcodeGen.
- The founding flag (done): `app_config.founding_open` plus a trigger on new households, with pgTAP tests.
- A smoke test against staging: sign in, create a household, build a week. Then the first TestFlight build.
- Update `docs/app-store-submission.md` and close #37.

## What to send me
- [x] The project ref and Project URL, and the three GitHub secrets.
- [ ] The publishable key, only for my local smoke test. It goes straight into Xcode Cloud, so you can skip sending it.
- [ ] Confirmation that the Apple secrets are set and the Apple provider is on.
- [ ] Confirmation that the App Store Connect app and the Family group exist.
- [ ] Confirmation that the Xcode Cloud workflow exists, or tell me to do step 4 with you.
- [ ] Your answers to the two decisions.
