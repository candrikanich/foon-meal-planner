-- A staple marked out puts its own line on the quick list, and marking it back in takes that line off (#203). Something added to
-- the same line afterward, a pivot for tonight or a tap by hand, merges into it, and the merged line has to stop reading as
-- the staple's, or marking in would take the newer need off with it. So a merge into a staple's line takes the incoming source.
-- add_to_list runs as the caller, so the merge needs update on source. It gives nobody more than they had: any member can
-- already delete a line or add one with any source.
grant update (source) on public.list_items to authenticated;

create or replace function public.add_to_list(
  target_household uuid,
  target_item uuid,
  target_list public.list_kind,
  item_urgency public.list_urgency default 'whenever',
  item_source public.list_item_source default 'manual',
  item_note text default null,
  line_id uuid default null,
  item_quantity text default null,
  item_plan uuid default null
)
returns public.list_items
language sql security invoker set search_path = ''
as $$
  insert into public.list_items as existing (id, household_id, item_id, list, urgency, source, note, quantity, plan_id)
  values (coalesce(line_id, gen_random_uuid()), target_household, target_item, target_list, item_urgency,
          item_source, item_note, item_quantity, item_plan)
  on conflict (household_id, list, item_id) where checked_at is null do update
    set urgency = case when excluded.urgency = 'tonight' then 'tonight'::public.list_urgency else existing.urgency end,
        note = public.merge_line_notes(existing.note, excluded.note),
        quantity = coalesce(existing.quantity, excluded.quantity),
        source = case when existing.source = 'staple' then excluded.source else existing.source end
  returning *;
$$;
