#!/usr/bin/env python3
"""
Files the Foon backlog into a GitHub repo: labels, milestones, and issues.

Usage:
  gh auth login                      # once
  python3 create_issues.py OWNER/REPO            # dry run (prints what it would do)
  python3 create_issues.py OWNER/REPO --apply    # actually create

Requires the GitHub CLI (gh). Safe to re-run: skips labels/milestones/issues
whose names or titles already exist.
"""
import json
import subprocess
import sys

MILESTONES = [
    ("M0 Foundation", "Project, Supabase schema with RLS, auth, households, invites, catalog seed."),
    ("M1 Sunday Flow (TestFlight alpha)", "Onboarding, library, This Week day cards, Build my week, swap, approve, shopping list, store mode. First internal TestFlight."),
    ("M2 Family Loop", "Ideas inbox, share extension, notifications, after-dinner loop, polls, staples, prep reminders, Family tab."),
    ("M3 Wow Layer", "On-device AI and household job queue, receipts, widgets, Siri, recap, contextual tips."),
    ("M4 Launch", "StoreKit with founding families, legal, App Store submission."),
]

LABELS = [
    ("phase-0", "5319e7"), ("phase-1", "1d76db"), ("phase-2", "0e8a16"),
    ("phase-3", "fbca04"), ("phase-4", "d93f0b"),
    ("ios", "c5def5"), ("supabase", "bfdadc"), ("algorithm", "f9d0c4"),
    ("ux", "d4c5f9"), ("infra", "ededed"), ("ai", "fef2c0"), ("legal", "e99695"),
]

M0, M1, M2, M3, M4 = (m[0] for m in MILESTONES)


def issue(title, milestone, labels, context, criteria):
    body = context.strip() + "\n\n## Acceptance criteria\n" + "\n".join(f"- [ ] {c}" for c in criteria)
    body += "\n\nSee CLAUDE.md and the product spec for context."
    return {"title": title, "milestone": milestone, "labels": labels, "body": body}


ISSUES = [
    # ---------------- Phase 0: Foundation ----------------
    issue("Create Xcode multiplatform project and repo structure", M0, ["phase-0", "ios", "infra"],
          "SwiftUI multiplatform app (iOS 26 / macOS 26) with the folder layout from CLAUDE.md.",
          ["App builds and runs on iPhone simulator and Mac", "Folders: App, Features, Core, DesignSystem, FoonTests",
           "Swift 6 strict concurrency enabled", "Placeholder tab bar: This Week, Library, Lists, Ideas, Family"]),
    issue("CI: GitHub Actions build and test", M0, ["phase-0", "infra"],
          "Run build and unit tests on every PR.",
          ["Workflow builds iOS and macOS schemes", "Swift Testing suite runs", "Supabase migrations and pgTAP tests run against a local Supabase in CI"]),
    issue("Supabase project setup and app configuration", M0, ["phase-0", "supabase", "infra"],
          "Init supabase/ with the CLI; wire supabase-swift into the app.",
          ["supabase/ folder with config, migrations, functions, seed, tests", "Local dev via `supabase start` documented in README",
           "URL and anon key injected via xcconfig per environment (local, staging, prod); not committed", "SupabaseService actor exposes a shared client"]),
    issue("Schema: households, members, allergies with RLS helpers", M0, ["phase-0", "supabase"],
          "Core tenancy tables and helper functions is_household_member and is_household_planner.",
          ["households(name, emoji, owner, settings jsonb, founding bool, subscription_status)",
           "members(household_id, first_name, avatar, role owner|planner|member, status active|away, away_until, user_id nullable, attendance_defaults jsonb, notification_prefs jsonb)",
           "member_allergies(member_id, category, custom_text)", "RLS on all three; planners write, members read; members can edit own avatar, schedule, notification prefs",
           "pgTAP tests prove cross-household isolation"]),
    issue("Schema: catalog, meals, ingredients, items", M0, ["phase-0", "supabase"],
          "Shared catalog (public read) plus household library tables.",
          ["catalog_meals and catalog_ingredients (read-only to clients)",
           "meals(household_id, catalog_meal_id nullable, name, servings, tags, prep_steps jsonb, source_url, photo_path, made_by_member_id, status active|trial|archived|retired)",
           "meal_ingredients(meal_id, item_id, quantity_text nullable)", "items(household_id, canonical_name, category, keep_on_hand bool, stock_state in|low|out)",
           "RLS and pgTAP tests"]),
    issue("Schema: plans, nights, attendance, list items", M0, ["phase-0", "supabase"],
          "Tables needed for the Sunday flow.",
          ["plans(household_id, week_start, approved_at)", "plan_nights(plan_id, date, effort normal|rushed|full|event, dinner_time, meal_id nullable, quick_pick nullable, locked bool)",
           "night_attendance(plan_night_id, member_id, expected bool)", "list_items(household_id, item_id, list weekly|quick, urgency, source, note, checked_at, checked_by)",
           "Realtime enabled on list_items", "RLS and pgTAP tests"]),
    issue("Sign in with Apple via Supabase Auth", M0, ["phase-0", "ios", "supabase"],
          "Only auth method. Session persists across launches.",
          ["Sign in with Apple button on welcome screen", "Supabase session stored and refreshed", "Sign out in Family tab (placeholder)", "Works on iOS and macOS"]),
    issue("Household creation and member profiles", M0, ["phase-0", "ios", "supabase"],
          "Owner creates a household and profiles for each family member before anyone else installs.",
          ["Create household with name and emoji", "Add, edit, and set role and status for members", "Owner auto-created as first member linked to their user",
           "Away status with optional return date"]),
    issue("Invites with link plus code, and claim-a-profile", M0, ["phase-0", "ios", "supabase"],
          "Invite via iMessage share sheet. Code fallback because install loses link context.",
          ["invites(household_id, member_id, code, expires_at, redeemed_at)", "Edge Function redeem_invite validates code and links user to member",
           "Share sheet message includes universal link and code (e.g. SMITH-4821)", "After sign-in, new user can enter code to claim their profile",
           "Only owner and planners can create invites"]),
    issue("Seed the starter catalog", M0, ["phase-0", "supabase"],
          "Seed ~69 dishes from the spec's Starter Pack tab with categories, tags, popular flag, and ingredient lists.",
          ["supabase/seed/catalog.sql loads all dishes", "Tags: quick, grill, slow_cooker, thaw_first, leftovers, backup, beginner",
           "Each dish has a reasonable ingredient list and default servings", "Placeholder image path per dish (photos come later)"]),
    issue("Local cache and sync skeleton (SwiftData)", M0, ["phase-0", "ios"],
          "Offline-first for the current plan and lists.",
          ["SwiftData models mirror plan, nights, list items", "SyncService pulls on launch and on Realtime events",
           "Offline writes queue and replay when online", "Unit tests for queue replay ordering"]),
    issue("Age assurance and parental consent (Texas rules, COPPA)", M0, ["phase-0", "ios", "legal"],
          "Handle Apple's age signals and parental consent from the start. See the spec's Risks, privacy, and outliers section.",
          ["Integrate Declared Age Range API; store only an age band flag, never a birthdate",
           "Respect PermissionKit significant-change flow and consent revocation (degrade gracefully when revoked)",
           "Explicit parental consent step when an adult creates a kid's profile; consent logged with timestamp",
           "Sandbox-tested per Apple's age assurance testing environment"]),
    issue("Storage security and photo metadata stripping", M0, ["phase-0", "supabase", "ios"],
          "Family photos must not leak location or be publicly reachable.",
          ["Private storage buckets with household-scoped policies", "Short-lived signed URLs for all images",
           "EXIF/GPS and other metadata stripped client-side before upload", "pgTAP or integration test proving cross-household access is denied"]),
    issue("Security hardening: invites, roles, sessions", M0, ["phase-0", "supabase"],
          "Close the obvious abuse paths early.",
          ["Invite codes single-use, expiring, rate-limited, at least 8 unambiguous characters",
           "RLS tests: members cannot change roles or edit others' allergies", "Sign out of all devices; member removal revokes sessions immediately"]),

    # ---------------- Phase 1: Sunday Flow ----------------
    issue("Design system: colors, type, DayCard component", M1, ["phase-1", "ios", "ux"],
          "Warm palette (paprika/tomato primary, cream background, deep green accent), light and dark mode.",
          ["Color and type tokens", "DayCard view: day/date, effort chip, attendance avatars, meal slot with photo, reason chip, badges, lock/shuffle/swap actions",
           "Read-only variant for members", "Previews for empty, planned, locked, event, and flagged states"]),
    issue("Allergy matching module", M1, ["phase-1", "ios", "algorithm"],
          "Deterministic keyword matching of ingredients to the 9 major allergens plus custom.",
          ["Keyword map per category (e.g. casein/butter -> milk, tahini -> sesame)", "flags(for meal, members) returns allergens and affected members",
           "Substitution table (milk -> oat milk, cheese -> dairy-free cheese, etc.)", "Unit tests with tricky ingredient names"]),
    issue("Onboarding flow", M1, ["phase-1", "ios", "ux"],
          "Welcome, household name, add family, allergies, pick dinners, rhythm, invite, land on This Week in edit mode. Target: under 3 minutes.",
          ["All steps implemented; allergies and invite are skippable", "Dinner picker: popular first, category tabs, search, Show more; tapped dishes copy into the library",
           "Catalog dishes with flagged allergens show a warning but stay selectable", "Rhythm: planning day/time, week start, dinner time, notification preset",
           "Ends on This Week with Fill my week highlighted",
           "'Load a sample family' option on the first screen creates demo members, meals, and a planned week (for App Review and curious users)"]),
    issue("Meal library screen", M1, ["phase-1", "ios"],
          "Two-column photo grid with search, filter chips, and sorts.",
          ["Filters: Favorites, Quick, Trying, Backup, Allergy flags, Archived", "Sorts: Haven't had in a while, Most made, Recently added",
           "Long-press: plan it, archive", "Browse ideas (catalog) entry point"]),
    issue("Meal detail screen", M1, ["phase-1", "ios"],
          "View and edit a meal.",
          ["Photo (replace with own), name, tags, allergy flags with Make it safe", "Editable ingredient list with Add to list",
           "Optional recipe steps and source link", "History: times made, last made (stub until logs exist)", "Actions: Plan it, Copy and tweak, Archive"]),
    issue("Quick add with natural-language ingredient parsing", M1, ["phase-1", "ios", "algorithm"],
          "Type a name and ingredients like '1 lb ground beef, taco shells, cheese'.",
          ["Deterministic parser splits items and optional quantities", "Autocomplete from household items", "Save with name only; 'add ingredients' badge when empty",
           "Unit tests for the parser"]),
    issue("Recipe link import via schema.org", M1, ["phase-1", "supabase", "ios"],
          "Edge Function fetches a URL and parses JSON-LD Recipe data.",
          ["Edge Function returns name, servings, ingredients, steps, image URL", "Ingredients scaled to household size on import",
           "Falls back to saving title and link as an idea when no recipe data", "Paste-link entry in Add flow"]),
    issue("Attendance defaults and week generation", M1, ["phase-1", "ios", "supabase"],
          "Creating a week builds 7 nights from the week-start setting with attendance from member defaults.",
          ["Members' usual weekday schedule pre-fills attendance", "Away members excluded until their return date",
           "Tap avatar on a DayCard toggles attendance", "Effort chip cycles normal -> rushed -> full -> event"]),
    issue("This Week screen", M1, ["phase-1", "ios", "ux"],
          "Wallet-style stack of DayCards with tonight on top.",
          ["Empty state: requests waiting summary and Build my week button (members see 'Add your requests')",
           "Planned state with past nights collapsed", "Partly planned: dashed empty cards with Fill and Fill remaining nights",
           "Cart icon with badge count opens Lists", "Inline lock, shuffle, swap; tap opens night detail"]),
    issue("Build my week algorithm", M1, ["phase-1", "algorithm"],
          "Pure function: (library, history, attendance, effort, settings, requests, seed) -> draft with reason chips.",
          ["Locks dated requests, events, pinned meals", "Fills leftover/takeout/new-dish slots per settings",
           "Filters: repeat window, snoozed, disliked by anyone home, retired, effort fit (rushed = quick only), grill/advance prep fit",
           "Weighted random scoring: days since last made, favorites of who's home, items on hand, overall likes", "Each pick returns a human-readable reason",
           "Shuffle re-rolls one night without changing locked ones", "Thorough unit tests with fixed seeds"]),
    issue("Swap sheet", M1, ["phase-1", "ios", "ux"],
          "Replace a night's meal.",
          ["3 suggestions with reason chips (from the algorithm)", "Quick picks: Leftovers, Takeout, Eat out, Fend for yourselves, Freezer raid",
           "Search library, then catalog results below", "Inline quick add"]),
    issue("Approve week and generate weekly shopping list", M1, ["phase-1", "algorithm", "supabase"],
          "Approval turns the plan into a list.",
          ["Merges ingredients across meals, dedupes by canonical item", "Excludes items marked in stock", "Adds low/out keep-on-hand staples",
           "Allergy notes on flagged items ('get dairy-free')", "Approve button shows item count; This Week cart badge updates", "Unit tests for merge logic"]),
    issue("Lists screen and store mode", M1, ["phase-1", "ios", "ux"],
          "Weekly and quick lists, plus a focused in-store mode.",
          ["List sections: On the list, Staples running low, Add item", "Store mode: grouped by category, big tap targets, checked items sink, screen stays awake",
           "Works offline; Realtime sync when two shoppers split up", "'Couldn't find it' moves item to quick list", "Finish trip action"]),
    issue("Observability: Sentry and privacy-first analytics", M1, ["phase-1", "infra"],
          "Know when things break and which flows people use, without tracking anyone.",
          ["Sentry in the iOS app and Edge Functions with PII scrubbing", "TelemetryDeck (or PostHog, anonymized) for key funnel events: onboarding steps, first plan, approve, store mode",
           "No ad SDKs; no App Tracking Transparency prompt needed", "Privacy manifest updated"]),
    issue("Account deletion and data export", M1, ["phase-1", "ios", "supabase", "legal"],
          "Apple requires in-app account deletion.",
          ["Delete my account (member) and Delete household (owner) flows with confirmation", "Revokes the Sign in with Apple token on deletion",
           "Household data export (JSON) for planners", "Removed members keep anonymized history for ratings"]),
    issue("Graceful edge cases in planning", M1, ["phase-1", "algorithm", "ux"],
          "Don't break when real families don't fit the defaults.",
          ["Fewer than 7 library meals: fill what's possible and suggest catalog dishes", "Single-member and 8+ member households work",
           "All user-facing strings localizable from day one"]),
    issue("Standing traditions (recurring nights)", M1, ["phase-1", "algorithm", "ios"],
          "Taco Tuesday, Pizza Friday: a recurring meal or quick pick per weekday.",
          ["Planner sets a standing meal for a weekday", "Build my week auto-fills it and marks it locked with a 'Tradition' reason chip",
           "Swappable for a single week without removing the tradition", "Unit tests in the algorithm"]),
    issue("Side dish pairings", M1, ["phase-1", "ios", "algorithm"],
          "Meals can carry optional sides so the list is complete.",
          ["Meals have optional side pairings (other meals or simple items: salad, garlic bread)", "Sides shown on the DayCard and meal detail",
           "Sides' ingredients flow into the weekly list on approval"]),
    issue("Non-food items, item notes and brands", M1, ["phase-1", "ios"],
          "One list for the whole household run.",
          ["Items can be non-food with categories (household, personal care)", "Per-item note or brand preference shown on lists and in store mode",
           "Non-food items work as keep-on-hand staples too"]),
    issue("Landing page with founding-family waitlist", M1, ["phase-1", "infra"],
          "Nuxt site on Vercel; also supplies the App Store URLs.",
          ["Home page: mission, tagline, screenshots, founding-family offer (free in beta, 50% off annual for life)",
           "Waitlist form storing emails in Supabase; confirmation email via Resend", "Privacy policy, terms, and support pages at stable URLs",
           "Domain chosen after the name check (available on 2026-10-25: getfoon.com, usefoon.com, foon.family)"]),
    issue("Reserve social media accounts", M1, ["phase-1", "infra"],
          "Lock the handle everywhere once the name is confirmed.",
          ["Same handle reserved on Instagram, TikTok, Facebook, and X", "Profile image (Foon spork), bio with tagline, link to landing page",
           "Handles listed in the landing page footer"]),
    issue("Internal metrics dashboard", M1, ["phase-1", "infra"],
          "Track whether Foon shares the load, anonymously.",
          ["North star: share of dinners with a contribution from someone other than the planner",
           "Onboarding completion, time to first plan, weekly active households, plans approved, after-dinner response rate, contributors per household, shopping trips, W1/W4 retention, trial-to-paid",
           "Aggregated and anonymized; no individual tracking"]),
    issue("TestFlight pipeline and founding flag", M1, ["phase-1", "infra"],
          "Ship M1 to internal testers.",
          ["Signing and build numbering automated (Xcode Cloud or fastlane)", "Internal TestFlight group for our family",
           "Households created during beta get founding = true", "Basic crash reporting enabled"]),

    # ---------------- Phase 2: Family Loop ----------------
    issue("Ideas inbox", M2, ["phase-2", "ios", "supabase"],
          "Requests from anyone; drives planning.",
          ["requests table with RLS", "Sections: For this week, Someday, New finds", "'I want...' button: library pick, link, photo, free text, optional night",
           "+1 (me too), statuses Waiting/Planned/Tried", "Planner actions: Plan it, Save to library, Not this week, Save for special occasion, Archive",
           "Multi-+1 requests get top priority in Build my week", "Requester notified when planned"]),
    issue("Share Sheet extension", M2, ["phase-2", "ios"],
          "One share target for links, screenshots, PDFs, and text.",
          ["Recipe links -> import or idea", "Social links -> caption parse, else idea with title and link", "Images and PDFs -> text recognition then ingredient parse",
           "Plain text -> quick shopping list"]),
    issue("Notification infrastructure", M2, ["phase-2", "supabase", "infra"],
          "APNs from Edge Functions on a schedule, with logging for budgets and ignore rules.",
          ["Device token registration", "Scheduled Edge Function evaluates due notifications per household timezone", "notification_log with sent/responded",
           "Per-member budgets, quiet hours, and school-hours window enforced",
           "All 12 notification types built; only 4 on by default (plan set, prep reminder, day-of check-in, after-dinner prompt), the rest off but available in settings"]),
    issue("Day-of check-in", M2, ["phase-2", "ios"],
          "Afternoon 'You home?' with dinner preview.",
          ["Adult-set time, default after school", "No answer = home", "Planners notified only on changes", "Leftovers predicted and swap offered when the reason for the pick is out"]),
    issue("After-dinner prompt, reactions, and dislike rules", M2, ["phase-2", "ios", "supabase"],
          "Rich notification card; one tap saves.",
          ["meal_logs and reactions tables with RLS", "Notification content extension with reaction row, Wasn't home, We had something else",
           "First responder: leftovers yes/no and who cooked, pre-filled", "Auto-confirm overnight as unverified", "Reactions editable for 24 hours",
           "Dislike rule and favorites feed the algorithm", "Missed-prompt card on This Week; pass-the-phone mode"]),
    issue("Tonight poll", M2, ["phase-2", "ios", "supabase"],
          "Vote among who's home tonight.",
          ["polls and votes tables", "Options from backup dinners in stock, quick picks, and suggestions", "Closes at set time; no vote = abstain"]),
    issue("Keep-on-hand staples and quick list urgency", M2, ["phase-2", "ios"],
          "In/low/out staples and backup dinners.",
          ["Tap low/out from anywhere", "Pivots add missing ingredients to the quick list with urgency", "Urgent items notify adults; others don't"]),
    issue("Prep reminders", M2, ["phase-2", "ios", "supabase"],
          "Thaw, marinate, slow cooker start, relative to dinner time.",
          ["Prep steps per meal; keyword detection suggests them", "'We keep meat frozen' household toggle", "Actions: Done, Remind me in an hour, Swap"]),
    issue("Cook credit, serving notes, cook mode", M2, ["phase-2", "ios"],
          "Grow more cooks.",
          ["Cooked-this-month tally and Thanks chef", "Per-person serving notes shown on cards and in cook mode", "Cook mode: one step per screen, timers, screen awake"]),
    issue("Family tab and notification settings", M2, ["phase-2", "ios", "ux"],
          "Members, rhythm, presets, advanced settings.",
          ["Member detail: role, status, usual schedule (kids edit own), allergies (adults edit), taste profile, cook tally",
           "Household rhythm and planning mix defaults", "Presets Light/Balanced/Engaged plus advanced per-member overrides",
           "Ignore handling: downshift to weekly roundup; gentle re-enable prompt", "Privacy summary, export, delete household"]),

    issue("Transactional email with Resend (adults only)", M2, ["phase-2", "supabase", "infra"],
          "Email for adults; never kids.",
          ["Register sending domain with Apple's private email relay service so relay addresses deliver",
           "Templates: owner welcome, adult invite fallback, subscription and deletion receipts", "Optional weekly plan email for planners (opt-in)",
           "Opt-in founding-family updates with unsubscribe (CAN-SPAM)"]),
    issue("Household shapes and recurring rules", M2, ["phase-2", "supabase", "algorithm"],
          "Outliers from the spec: custody, toddlers, food rules, split dinners.",
          ["Recurring away patterns (e.g. every other week) on member schedules", "Member flag 'eats separately' excludes them from ratings and votes",
           "Recurring household food rules (e.g. no meat on Fridays during Lent) respected by the algorithm",
           "Data model supports two seatings per night (UI can come later)", "Planners can hide a comment"]),

    issue("Claim a night and dinner jobs", M2, ["phase-2", "ios", "supabase"],
          "Voluntary cooking and helper tasks.",
          ["'I'll cook Thursday' claim on any DayCard; shown with avatar; feeds cook credit", "Planners notified of claims",
           "Optional rotating dinner jobs (set table, dishes) per night, configurable per household"]),
    issue("Heading to the store broadcast", M2, ["phase-2", "ios"],
          "Let the family add last-minute items.",
          ["One tap in Lists sends 'Dad's at the store, add anything in the next 10 minutes'", "Items added during the window are highlighted in store mode",
           "Respects notification settings and budgets"]),
    issue("Vacation or pause mode and season templates", M2, ["phase-2", "ios", "supabase"],
          "Families travel and schedules change by season.",
          ["Mark away dates for the whole household: no planning, notifications, or list building", "Save named attendance templates (school year, baseball season, summer) and switch between them"]),
    issue("Cook once, eat twice and freezer stash", M2, ["phase-2", "ios", "algorithm"],
          "Planned leftovers and meals cooked ahead.",
          ["'Double it' on a night plans a leftovers night and scales the list", "Freezer stash list of cooked-ahead meals with dates",
           "Freezer stash meals offered in swap sheet and tonight poll"]),
    issue("Seasonal weighting and variety nudges", M2, ["phase-2", "algorithm"],
          "Smarter suggestions without nutrition tracking.",
          ["Grill and cold dishes weighted up in summer; soups and slow cooker in winter", "Variety nudges for repeated categories (e.g. pasta 3 times)",
           "No calorie or nutrition tracking", "Unit tests"]),
    issue("Cooking start time and kitchen equipment", M2, ["phase-2", "ios", "algorithm"],
          "Timing and capability-aware suggestions.",
          ["Optional 'start cooking at' nudge computed from prep time and dinner time", "Household equipment list (air fryer, Instant Pot, grill, slow cooker)",
           "Suggestions filtered by equipment the household owns"]),
    issue("Family stats card", M2, ["phase-2", "ios", "ux"],
          "Show families the load being shared.",
          ["Stats: dinners planned together, ideas from non-planners, nights cooked by others, family dinners at the table, new dishes tried",
           "Estimated planning time saved, labeled as an estimate", "Shown on the Family tab and in the weekly recap"]),
    issue("Change history and undo", M2, ["phase-2", "ios", "supabase"],
          "Two planners shouldn't confuse each other.",
          ["Activity log of plan changes ('Dad swapped Tuesday to tacos')", "Undo the last change on a night", "Shown on night detail and in a household activity view"]),

    # ---------------- Phase 3: Wow Layer ----------------
    issue("AI capability detection and household AI job queue", M3, ["phase-3", "ai", "supabase", "ios"],
          "Capable devices process AI jobs for the whole household.",
          ["ai_jobs table with claim/complete", "Capable devices claim on launch and via background tasks", "Instant partial results; timeout falls back to non-AI path"]),
    issue("AI recipe capture and prep-step detection", M3, ["phase-3", "ai"],
          "Foundation Models with guided generation to structure captions, OCR text, and recipes.",
          ["Structured output: name, ingredients, steps, prep steps", "Runs via the job queue", "Non-AI fallback unchanged"]),
    issue("Tonight rescue", M3, ["phase-3", "ai", "algorithm"],
          "'20 minutes, what can we make?' from pantry, leftovers, backups, who's home.",
          ["Code-based candidates; AI phrasing on capable devices", "Works without AI"]),
    issue("Receipt scanning", M3, ["phase-3", "ios", "algorithm"],
          "Photo or forwarded email receipt.",
          ["Vision text recognition; fuzzy match to items; learns from corrections", "Marks items in stock and clears list", "Suggests new keep-on-hand staples"]),
    issue("Widgets and App Intents", M3, ["phase-3", "ios"],
          "Tonight's dinner widget; Siri phrases.",
          ["Home and lock screen widget: tonight's meal", "Intents: add to list, what's for dinner, request a meal"]),
    issue("Weekly recap and contextual tips", M3, ["phase-3", "ios", "ux"],
          "Fun stats and first-use feature tours.",
          ["Recap: dinners, cooks, top dish, forgotten favorite", "One-time tip cards on first use of share sheet, AI pick, store mode", "Show tips again setting"]),

    issue("Calendar awareness (on-device, read-only)", M3, ["phase-3", "ios", "algorithm"],
          "Use the family calendar to spot busy nights without sending anything off the phone.",
          ["EventKit read access with clear permission prompt; off by default", "Events in a chosen dinner window pre-mark the night as rushed (suggestion, not override)",
           "Calendar data never uploaded or stored server-side"]),
    issue("Picky-eater wins and dinner memories", M3, ["phase-3", "ios"],
          "Celebrate trying new food; keep family dinner memories.",
          ["Per-member 'tried new dishes' count and gentle celebration", "Photo timeline of dinners from family photos",
           "Yearly recap (top dishes, cooks, new tries)"]),

    # ---------------- Phase 4: Launch ----------------
    issue("StoreKit subscriptions and household entitlement", M4, ["phase-4", "ios", "supabase"],
          "$5.99/mo or $49.99/yr, 30-day trial; Founding Family annual product at $24.99/yr, locked for life, for flagged households (free during beta).",
          ["Two subscription products; founding households see the founding one", "Server-side entitlement on household via App Store Server Notifications",
           "Owner pays; whole household unlocked", "Ownership transfer"]),
    issue("Privacy policy, terms, and legal review", M4, ["phase-4", "legal"],
          "Kids' data, COPPA, allergy disclaimer.",
          ["Privacy policy and terms published", "App Store privacy label completed", "Allergy helper disclaimer in UI and terms",
           "Written data-retention policy with time periods (amended COPPA rule)", "Explicit opt-in consent for allergy (health) data",
           "Receipt images deleted after parsing", "Legal review before submission"]),
    issue("App Store submission", M4, ["phase-4", "infra"],
          "Listing and release.",
          ["All fields from the spec's App Store Submission tab entered (listing, keywords, description, subscriptions, privacy label, age rating, review notes)",
           "'Load a sample family' demo mode for reviewers", "Compliance checklist in that tab complete",
           "Name and subtitle: Foon: Family Dinner Planner / Plan, vote, shop. Together.", "Screenshots and preview",
           "Enrolled in App Store Small Business Program", "Founding 50 recruited via TestFlight"]),
]


def run(cmd, apply):
    print(("$ " if apply else "[dry-run] ") + " ".join(cmd[:6]) + (" ..." if len(cmd) > 6 else ""))
    if apply:
        return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    return ""


def existing(repo, kind):
    if kind == "labels":
        out = subprocess.run(["gh", "label", "list", "-R", repo, "--limit", "200", "--json", "name"], capture_output=True, text=True).stdout or "[]"
        return {x["name"] for x in json.loads(out)}
    if kind == "milestones":
        out = subprocess.run(["gh", "api", f"repos/{repo}/milestones?state=all&per_page=100"], capture_output=True, text=True).stdout or "[]"
        return {x["title"] for x in json.loads(out)}
    if kind == "issues":
        out = subprocess.run(["gh", "issue", "list", "-R", repo, "--state", "all", "--limit", "500", "--json", "title"], capture_output=True, text=True).stdout or "[]"
        return {x["title"] for x in json.loads(out)}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    repo, apply = sys.argv[1], "--apply" in sys.argv
    have_labels = existing(repo, "labels") if apply else set()
    have_ms = existing(repo, "milestones") if apply else set()
    have_issues = existing(repo, "issues") if apply else set()

    for name, color in LABELS:
        if name not in have_labels:
            run(["gh", "label", "create", name, "-R", repo, "--color", color], apply)
    for title, desc in MILESTONES:
        if title not in have_ms:
            run(["gh", "api", f"repos/{repo}/milestones", "-f", f"title={title}", "-f", f"description={desc}"], apply)
    for it in ISSUES:
        if it["title"] in have_issues:
            continue
        cmd = ["gh", "issue", "create", "-R", repo, "--title", it["title"], "--body", it["body"], "--milestone", it["milestone"]]
        for l in it["labels"]:
            cmd += ["--label", l]
        run(cmd, apply)
    print(f"\n{len(ISSUES)} issues across {len(MILESTONES)} milestones." + ("" if apply else " Dry run only; add --apply to create."))


if __name__ == "__main__":
    main()
