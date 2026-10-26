# #9 Invites with link plus code, and claim-a-profile — plan

## Flow
1. **Inviting.** A member's detail sheet has **Invite** on profiles that aren't claimed yet.
   - It creates an invite and opens the share sheet (iMessage) with: "Join The Andrikanichs on Foon. Tap the link, or enter code ANDRI-7KQ4-M9XP after you sign in."
   - The Family row shows "Invite sent" until the invite is redeemed, expires, or is replaced.
2. **Claiming.** The new person installs, signs in with Apple, and lands on "Welcome to Foon", which gains **Have an invite code?** If they opened the link, the code is already filled in.
   - Redeeming links their account to that profile and drops them into the household's tabs.

## Code format
`ANDRI-7KQ4-M9XP`:
- The prefix is the first five letters of the household name. It's cosmetic, so the code feels familiar in a text.
- After it come **8 random characters** from an unambiguous alphabet (no 0, O, 1 or I), about 40 bits.
- Entry ignores case, spaces and dashes.
- This satisfies #14 ("at least 8 unambiguous characters") and keeps the spec's "SMITH-4821" feel.

## Rules (server-enforced)
- **Single-use.** Expires after 7 days. A new invite for the same profile replaces the old one.
- **Only stored hashed** (SHA-256). The plain code is shown once, at creation; "Invite again" makes a new one.
- **Only unclaimed, non-removed profiles** can be invited. A removed member is never re-linked by an old invite (carried over from #75).
- **Redeeming requires the person to have no household yet** (one household per person).
- **Rate limit:** 5 failed redeem attempts per account per 15 minutes. Failed attempts are recorded even though the redeem fails, because the function returns a status instead of raising.
- **Same answer for every bad code:** "That code didn't work". Nothing reveals whether a code exists.

## Data
- `invites(household_id, member_id, code_hash, created_by, created_at, expires_at, redeemed_at, redeemed_by, revoked_at)`
  - RLS: household managers can read their household's invites (no plain codes are ever stored).
  - No client writes; everything goes through the functions below.
- `invite_redeem_attempts(user_id, attempted_at, succeeded)` for rate limiting. No client access.
- `create_invite(member_id) returns text`: generates the code, stores the hash, revokes any earlier active invite for that profile, and returns the code.
- `redeem_invite(code) returns status`: `claimed | invalid | expired | used | has_household | rate_limited`.
  - On `claimed` it links `members.user_id`.
  - It's `SECURITY DEFINER`, with a guard-trigger allowance for privileged database functions, since today the trigger only lets service-role contexts change `user_id`.

## Client
- `InviteClient` (closure struct) with `createInvite(memberID)`, `redeem(code)` and `activeInvites(householdID)`.
- `InviteCode`: pure normalizing and formatting functions, unit-tested.
- Share via SwiftUI `ShareLink`. Handle `foon://invite/<code>` with `onOpenURL` and prefill the code.

## Tests
- pgTAP for every rule above, including the rate limit, removed profiles, a second household, an expired invite, a used invite, a revoked invite, and that a non-manager can't create invites.
- Swift unit tests for `InviteCode` and the store logic.
- Gated live test: user A creates a household and invites a profile; user B redeems and sees the household.
- Manual: invite yourself to a second Apple Account? That needs a second Apple ID or device; otherwise the live test covers it.

## Decisions (approved 2026-10-26)
1. **Parents only** create invites; the spec is updated from "Owner and Planners".
2. **Database function** for redeeming (`SECURITY DEFINER`), not an Edge Function.
3. **`foon://invite/<code>`** for now; universal links once a domain exists.
