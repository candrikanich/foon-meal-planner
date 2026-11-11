-- Privacy Policy v2 in force (#48, PR D). v2 adds what v1 didn't cover: the emails Foon sends adults (account notices,
-- and the weekly plan email and founding-family updates an adult can turn on), an emailed invite's address, the
-- waitlist getting only a launch email, and finished shopping trips (#315). The words are getfoon.com/privacy
-- (label PRIVACY_VERSION in web/app/content.ts) and docs/legal/privacy.md.
--
-- * privacy-draft-v2 is registered and in force at once. It requires agreeing again, so every adult sees the app's
--   "We updated our terms" gate once, with this summary, until they agree (account_agreement_status: an agreement to v1
--   no longer counts). Kids never see the gate. Nothing is held or erased: the Terms gate is the app's alone.
-- * weekly-plan-email-v1 and founding-updates-v1 (registered by 20261124000000_account_email_opt_in.sql, not in force)
--   go into force with the policy that lists them. Nothing reads them as a gate: an opt-in names its wording when it's
--   turned on, and a preference keeps the wording it was given to.
-- * account_email_enabled stays off. Turning it on is Chris's, once the relay and secrets are set (account-email.md).
--
-- now() is this transaction's start, so current_agreement_version (effective_at <= now()) sees these at once.

insert into public.agreement_versions (version, kind, ordinal, summary, effective_at) values
  ('privacy-draft-v2', 'privacy', 2,
   'The Privacy Policy now lists the emails Foon sends adults (account notices, plus a weekly plan email and founding-family updates only if you turn them on), and that Foon counts finished shopping trips, never what was bought.',
   now());

update public.agreement_versions
   set effective_at = now()
 where version in ('weekly-plan-email-v1', 'founding-updates-v1')
   and effective_at is null;
