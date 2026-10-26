# Foon

Family dinner planner for iOS. Different tastes. Same table.

Foon takes the weight of dinner off one person and shares it with the whole family: plan the week together, build the shopping list automatically, and log what everyone thought.

- Project rules and stack: [CLAUDE.md](CLAUDE.md)
- Product spec: [docs/spec.md](docs/spec.md), [starter pack](docs/starter-pack.md), [App Store submission](docs/app-store-submission.md)
- Backlog: GitHub Issues, grouped into milestones M0 to M4. `scripts/create_issues.py` files them (`python3 scripts/create_issues.py candrikanich/foon-meal-planner --apply`).

## Development

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

The Xcode project is generated from `project.yml` and not committed:

```sh
xcodegen generate      # after cloning, pulling, or adding files
open Foon.xcodeproj
```

Run unit tests (macOS destination, no simulator needed):

```sh
scripts/test.sh
```

## Local Supabase

Requires Docker and the [Supabase CLI](https://supabase.com/docs/guides/local-development) (`brew install supabase/tap/supabase`).
Ports are shifted to 544xx (API `54421`, DB `54422`, Studio `54423`) so Foon can run beside other local Supabase projects.

```sh
supabase start                   # boots the stack and applies supabase/migrations
scripts/write-local-config.sh    # writes Config/Local.local.xcconfig (gitignored) from `supabase status`
xcodegen generate
supabase db reset                # re-apply migrations and supabase/seed/*.sql
supabase test db                 # pgTAP tests in supabase/tests
TEST_RUNNER_FOON_LOCAL_SUPABASE=1 scripts/test.sh   # include tests that hit the local stack
supabase stop
```

### Environments

| Build configuration | Supabase | Settings file (gitignored) |
| --- | --- | --- |
| Debug | local stack | `Config/Local.local.xcconfig` |
| Staging | hosted staging | `Config/Staging.local.xcconfig` |
| Release | production | `Config/Prod.local.xcconfig` |

Copy the matching `*.local.xcconfig.example` to create each file. Staging and Release builds fail if their file is missing, so a hosted build can't ship unconfigured (CI or Xcode Cloud must write it from secrets). Only the URL and anon key live in the app; service-role keys belong in Edge Functions only.

### Starter catalog

`supabase/seed/catalog.sql` holds the 69 starter dishes from [docs/starter-pack.md](docs/starter-pack.md). It runs on every `supabase db reset` and is safe to re-run: dishes update in place by slug, and each dish's ingredient list is replaced. To change the catalog, edit both files, then run `supabase db reset` and `supabase test db`. Hosted environments get catalog changes with `supabase db push --include-seed`.

### Sign in with Apple (local)

The app signs in natively with Sign in with Apple and hands the identity token to Supabase Auth. The local stack enables the Apple provider with the App ID `com.andrikanich.foon` as the client ID; native sign-in needs no secret key. Sign in with Apple needs a signed build, so `CODE_SIGNING_ALLOWED=NO` builds (CI, `scripts/test.sh`) can't sign in:

```sh
xcodebuild build -project Foon.xcodeproj -scheme Foon -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedDataSigned -allowProvisioningUpdates
open build/DerivedDataSigned/Build/Products/Debug/Foon.app
```
