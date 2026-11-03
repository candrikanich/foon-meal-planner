-- Receipt scanning, photo half (#61). The photo is read on the phone and never leaves it; no receipt or receipt line is
-- stored. What's kept is what the family taught: a receipt line's text (as the app normalizes it: printed words without
-- prices, codes and flags, lowercased) is this item. Anyone in the family can teach it, kids too, since a correction
-- helps the whole household and checking off is open to everyone.
-- One alias per text per household. Correcting it again moves it to the new item; it's never deleted, and it goes with its
-- item or household (both only ever deleted with the household).

create table public.receipt_aliases (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  raw_text text not null
    check (char_length(raw_text) between 1 and 80 and raw_text = lower(btrim(raw_text))),
  item_id uuid not null,
  -- Set null, not cascade: what someone taught stays with the household after they're gone.
  created_by uuid references public.members (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (item_id, household_id) references public.items (id, household_id) on delete cascade,
  constraint receipt_aliases_household_text_key unique (household_id, raw_text)
);

create index receipt_aliases_item_idx on public.receipt_aliases (item_id, household_id);
create index receipt_aliases_created_by_idx on public.receipt_aliases (created_by);

create trigger receipt_aliases_set_updated_at before update on public.receipt_aliases
  for each row execute function public.set_updated_at();

revoke all on public.receipt_aliases from anon, authenticated;
grant select on public.receipt_aliases to authenticated;
grant insert (household_id, raw_text, item_id, created_by) on public.receipt_aliases to authenticated;
grant update (item_id) on public.receipt_aliases to authenticated;

alter table public.receipt_aliases enable row level security;

create policy "members read receipt aliases" on public.receipt_aliases
  for select to authenticated using (public.is_household_member(household_id));
create policy "members teach receipt aliases" on public.receipt_aliases
  for insert to authenticated
  with check (public.is_household_member(household_id)
              and (created_by is null or created_by = public.my_member_id(household_id)));
create policy "members correct receipt aliases" on public.receipt_aliases
  for update to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

-- Teach one line: insert, or move an existing alias to the new item. Runs under the caller's RLS, like ensure_item; the
-- composite foreign key keeps the item in the same household.
create function public.teach_receipt_alias(target_household uuid, alias_text text, target_item uuid)
returns public.receipt_aliases
language sql security invoker set search_path = ''
as $$
  insert into public.receipt_aliases as existing (household_id, raw_text, item_id, created_by)
  values (target_household, lower(btrim(alias_text)), target_item, public.my_member_id(target_household))
  on conflict (household_id, raw_text) do update set item_id = excluded.item_id
  returning *;
$$;

revoke execute on function public.teach_receipt_alias(uuid, text, uuid) from public, anon;
grant execute on function public.teach_receipt_alias(uuid, text, uuid) to authenticated;
