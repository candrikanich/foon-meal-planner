-- "Couldn't find it" (#196): the item moves to the quick list, in one step.
--
-- A phone sent this as an add and a delete, from what it had cached, maybe hours ago in a store with no signal. A refused add
-- still deleted the line, and a line changed since the tap went anyway, along with an allergy note it had gained. Here the
-- server reads the line as it is now, and either both happen or neither does.
--
-- Bought since the tap: nothing to move, so it's refused and the phone's next pull shows it bought. Gone since the tap (this
-- move already ran and its answer never arrived, or a plan change took it off): the add still happens, which merges into the
-- line a first try made, so a retry changes nothing. Under the caller's row-level security another household's line isn't found.

create function public.move_to_quick_list(
  target_line uuid,
  target_household uuid,
  target_item uuid,
  item_note text,
  line_id uuid,
  item_quantity text default null
)
returns public.list_items
language plpgsql security invoker set search_path = ''
as $$
declare
  original public.list_items;
  moved public.list_items;
begin
  select * into original from public.list_items where id = target_line for update;
  if original.checked_at is not null then
    raise exception 'that''s been bought since' using errcode = 'P0001';
  end if;

  -- The phone's note may already quote the line's, which merge_line_notes won't repeat. Anything added since goes on.
  select * into moved from public.add_to_list(target_household, target_item, 'quick', 'whenever', 'manual',
                                              public.merge_line_notes(item_note, original.note), line_id,
                                              coalesce(original.quantity, item_quantity), null);
  delete from public.list_items where id = original.id and id <> moved.id;
  return moved;
end;
$$;

revoke execute on function public.move_to_quick_list(uuid, uuid, uuid, text, uuid, text) from public, anon;
grant execute on function public.move_to_quick_list(uuid, uuid, uuid, text, uuid, text) to authenticated;
