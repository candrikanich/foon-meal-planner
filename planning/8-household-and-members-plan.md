# #8 Household creation and member profiles — plan

## Scope
In:
- data layer for households and members
- first-run "Create your household" screen
- Family tab: list, add and edit members
- adult or kid, guardian, role, Home or Away with a return date, Remove from household

Out:
- polished multi-step onboarding, dinner picker, rhythm, allergy question, invites (#17, #9)
- allergy editing UI (with #16 and #17)

## Screens
1. **Create your household** (signed in, no household yet)
   - Household name: placeholder "The Smiths", 1–50 characters.
   - Emoji: a row of eight suggestions plus "Other" for free text.
   - Your first name: prefilled from Sign in with Apple (`SessionStore.appleGivenName`).
   - One button: **Create household**. It lands on the tab bar.
2. **Family tab**
   - Header: the emoji and household name.
   - Member rows: avatar, first name, a "Parent" badge for guardians, and Kid or Adult, Planner or Member, and Home or "Away until Dec 20".
   - Removed members are hidden.
   - Toolbar: **Add member** (guardians only) and **Sign out**.
3. **Member editor** (a sheet, for add and edit)
   - **Who they are:** first name, avatar (an emoji grid), Adult or Kid, and Parent (adults only).
   - **Planning:** Planner or Member.
   - **Status:** Home or Away, with an optional return date.
   - **Remove from household** (guardians, with a confirmation; hidden on the owner).
   - What a non-guardian sees: their own row offers only the avatar, and other rows are read-only. The UI hides what RLS would reject anyway.

## Data
- New migration `create_household(name, emoji, first_name)`: a security-invoker SQL function that inserts the household and the owner's guardian profile in one transaction, so a failure can't leave a household without its owner profile. It has pgTAP tests.
- Swift models in `Core/Models`:
  - `Household` and `Member` (Codable, snake_case keys);
  - `AgeGroup`, `MemberRole`, `MemberStatus`;
  - `MemberDraft` with pure validation (trimmed name, 1–30 characters; kids can't be guardians).
- `HouseholdClient` (a closure struct like `AuthClient`): `myHousehold`, `createHousehold`, `members`, `addMember`, `updateMember`.
- `HouseholdStore` (`@Observable @MainActor`): load, create, add and update. Permission helpers `canManagePeople` and `canEdit(_ member:)` are pure, so they can be unit tested.
- Routing: signed in, then load the household. No household goes to Create; otherwise the tabs.

## Tests
- Unit (Swift Testing):
  - `MemberDraft` validation;
  - the permission helpers;
  - `HouseholdStore` with a fake client (load none or some, create, add, update, error messages);
  - decoding a real PostgREST row.
- pgTAP: `create_household` (atomic, owner is a guardian, refuses a second household, works through RLS).
- Gated live test (`FOON_LOCAL_SUPABASE`): sign up an email test user on the local stack, then create the household, add a kid, update to away, and remove, all through the real `.live` client. This catches PostgREST encoding and grant problems.
- Previews for every view, with mocks in `Core/Mocks`.

## Open questions
- None blocking. Confirm the emoji set when you see it.
