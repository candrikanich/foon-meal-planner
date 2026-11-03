-- A check-off follows a line "Couldn't find it" moved (#201).
--
-- Bob checks off milk offline. Alice's "Couldn't find it" reaches the server first and moves the weekly line to the quick list
-- under a new id. Bob's check-off then matched no row, which isn't an error, so it counted as sent, and milk in his cart read
-- as needed. The quick line now remembers the line it came from, so the phone can follow it.
--
-- It's set only when the move found the line: a retry, whose first try already moved it, leaves what that try set, and a line
-- that went another way (bought, removed, dropped by a plan change) leaves nothing to follow. A move that merges into an open
-- quick line marks that line: the item is one row on the phone, and checking it off there would have checked off both.
-- A line remembers only the latest move onto it. A second weekly line moved onto the same open quick line (next week's, say)
-- replaces the first, and a check-off still queued for the first then finds nothing to follow and does nothing. That's rare:
-- it takes two weeks' lines for one item and two "Couldn't find it"s while one phone stays offline.
-- Another household's line is never found under the caller's row-level security, so it's never named.

alter table public.list_items add column moved_from uuid;

create index list_items_moved_from_idx on public.list_items (moved_from) where moved_from is not null;

-- move_to_quick_list runs as the caller. Any member could already move, delete, or check off any line in their household.
grant update (moved_from) on public.list_items to authenticated;

create or replace function public.move_to_quick_list(
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
  if original.id is not null and original.id <> moved.id then
    update public.list_items set moved_from = original.id where id = moved.id returning * into moved;
  end if;
  delete from public.list_items where id = original.id and id <> moved.id;
  return moved;
end;
$$;
