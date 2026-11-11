-- Opt-in email (#48, PR C), part 1: the two agreement kinds an adult agrees to when they turn on an email.
-- On its own, before 20261124000000_account_email_opt_in.sql: Postgres can't use an enum value in the transaction that
-- added it, and each migration file is applied in its own transaction.
alter type public.agreement_kind add value if not exists 'weekly_plan_email';
alter type public.agreement_kind add value if not exists 'founding_updates';
