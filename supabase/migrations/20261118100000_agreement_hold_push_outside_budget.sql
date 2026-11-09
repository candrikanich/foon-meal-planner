-- #277: "Ava needs a parent's OK to keep using Foon." asks a parent to act, like Plan's set and urgent items, so it sits
-- outside the weekly push budget. Otherwise a parent whose week was full would lose it for good as over_budget, and the
-- hold job never queues it again because the hold already exists. The device leaves it out of its count too
-- (SentPush.outsideBudget). create or replace keeps the grants from 20261102230000 (service role only).
create or replace function public.push_outside_budget(row_kind text)
returns boolean
language sql immutable set search_path = ''
as $$
  select row_kind in ('plan_set', 'urgent_item', 'agreement_hold');
$$;
