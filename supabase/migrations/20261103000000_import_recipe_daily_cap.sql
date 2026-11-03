-- Recipe link import: a per-account daily cap (#116). The import-recipe Edge Function fetches any public page for a
-- signed-in caller, so a scripted account could spend the project's egress and invocation quota. It claims a slot
-- here, before fetching.
--
-- Per account, not per household: this is an abuse guard on the caller, not household-owned data, so household tenancy
-- doesn't apply (no household_id, no is_household_member). RLS is still on, with no client policies: nobody reads or
-- writes a counter directly, only claim_import_slot() touches it, and only ever for auth.uid().

create table public.import_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  imports int not null check (imports > 0),
  primary key (user_id, day)
);

alter table public.import_usage enable row level security;
revoke all on public.import_usage from public, anon, authenticated;

-- Counts one import against today's cap (30, UTC day) and says whether there was room. The increment is a single
-- upsert guarded by the cap, so concurrent calls can't both take the last slot. Rows older than a week are pruned on
-- the way past, so the table stays one-ish row per active account.
create function public.claim_import_slot()
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  caller uuid := auth.uid();
  today date := (now() at time zone 'utc')::date;
  claimed boolean;
begin
  if caller is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;

  delete from public.import_usage where user_id = caller and day < today - 7;

  insert into public.import_usage as usage (user_id, day, imports)
  values (caller, today, 1)
  on conflict (user_id, day) do update set imports = usage.imports + 1
    where usage.imports < 30
  returning true into claimed;

  return coalesce(claimed, false);
end;
$$;

revoke execute on function public.claim_import_slot() from public, anon;
grant execute on function public.claim_import_slot() to authenticated;
