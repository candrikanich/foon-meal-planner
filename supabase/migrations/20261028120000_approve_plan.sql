-- Approve to weekly list (#26).
-- 1. list_items.quantity: the amounts the week calls for ("1 lb + 1 lb"), shown on the list and in store mode;
--    list_items.plan_id: the week a weekly line was approved for, so one week's approval never touches another's.
-- 2. approve_plan stamps the plan approved and writes its weekly list in one transaction. The app builds the
--    lines (merged by item, minus what's in stock, plus low or out staples, with allergy notes); each entry is
--    {"item_id", "quantity"?, "note"?, "staple"?}. Approving again after a swap updates the list: the plan's
--    own open lines that are no longer needed go, its lines refresh, lines someone added by hand stay as they
--    are, and an item already bought for this week isn't listed again.

alter table public.list_items
  add column quantity text check (char_length(quantity) <= 60),
  add column plan_id uuid,
  add constraint list_items_plan_fkey foreign key (plan_id, household_id) references public.plans (id, household_id);

create index list_items_plan_idx on public.list_items (plan_id) where plan_id is not null;

grant insert (quantity, plan_id) on public.list_items to authenticated;
grant update (quantity) on public.list_items to authenticated;

create function public.approve_plan(target_plan uuid, lines jsonb)
returns void
language plpgsql security invoker set search_path = ''
as $$
declare
  household uuid;
begin
  -- Under the caller's row-level security another household's plan is simply not found.
  select household_id into household from public.plans where id = target_plan;
  if household is null then
    raise exception 'no plan %', target_plan using errcode = 'P0002';
  end if;
  if not public.is_household_planner(household) then
    raise exception 'only planners approve the week' using errcode = '42501';
  end if;
  if jsonb_typeof(lines) is distinct from 'array' then
    raise exception 'lines must be a JSON array' using errcode = '22023';
  end if;

  delete from public.list_items
  where plan_id = target_plan and checked_at is null
    and item_id not in (select (line ->> 'item_id')::uuid from jsonb_array_elements(lines) as line);

  insert into public.list_items as existing (household_id, item_id, list, source, quantity, note, plan_id)
  select household, (line ->> 'item_id')::uuid, 'weekly',
         case when (line ->> 'staple')::boolean then 'staple' else 'plan' end::public.list_item_source,
         nullif(btrim(line ->> 'quantity'), ''), nullif(btrim(line ->> 'note'), ''), target_plan
  from jsonb_array_elements(lines) as line
  where not exists (
    select 1 from public.list_items bought
    where bought.plan_id = target_plan and bought.item_id = (line ->> 'item_id')::uuid
      and bought.checked_at is not null
  )
  on conflict (household_id, list, item_id) where checked_at is null do update
    -- Refresh only what this week's plan wrote; a hand-added line, or another week's, keeps its own.
    set quantity = case when existing.plan_id = target_plan then excluded.quantity else existing.quantity end,
        note = case when existing.plan_id = target_plan then excluded.note else existing.note end;

  update public.plans set approved_at = now() where id = target_plan;
end;
$$;

revoke execute on function public.approve_plan(uuid, jsonb) from public, anon;
grant execute on function public.approve_plan(uuid, jsonb) to authenticated;
