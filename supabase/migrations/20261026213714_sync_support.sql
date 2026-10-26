-- Offline sync support (#11).
-- 1. add_to_list takes the line id the device already uses for a line added offline, so later
--    queued changes to that line (a check-off) hit the right row. A merge into an existing open
--    line still returns that line, and the device re-points its queued changes to it.
-- 2. Items join Realtime, so a staple tapped low or out on one phone reaches the others.

drop function public.add_to_list(uuid, uuid, public.list_kind, public.list_urgency, public.list_item_source, text);

create function public.add_to_list(
  target_household uuid,
  target_item uuid,
  target_list public.list_kind,
  item_urgency public.list_urgency default 'whenever',
  item_source public.list_item_source default 'manual',
  item_note text default null,
  line_id uuid default null
)
returns public.list_items
language sql security invoker set search_path = ''
as $$
  insert into public.list_items as existing (id, household_id, item_id, list, urgency, source, note)
  values (coalesce(line_id, gen_random_uuid()), target_household, target_item, target_list, item_urgency,
          item_source, item_note)
  on conflict (household_id, list, item_id) where checked_at is null do update
    set urgency = case when excluded.urgency = 'tonight' then 'tonight'::public.list_urgency else existing.urgency end,
        note = coalesce(existing.note, excluded.note)
  returning *;
$$;

revoke execute on function public.add_to_list(uuid, uuid, public.list_kind, public.list_urgency, public.list_item_source, text, uuid)
  from public, anon;
grant execute on function public.add_to_list(uuid, uuid, public.list_kind, public.list_urgency, public.list_item_source, text, uuid)
  to authenticated;

alter publication supabase_realtime add table public.items;
