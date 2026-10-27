-- Non-food items, item notes and brands (#33).
-- 1. Personal care joins household as a non-food category, so toothpaste and paper towels share the
--    list (and keep-on-hand) with groceries.
-- 2. items.note is the family's standing preference for an item ("Vanilla, not plain", "store brand"),
--    shown wherever the item appears. A list line's own note stays for one-off asks. Anyone at home may
--    set it, like stock; renaming and recategorizing stay with planners (items_guard_update).

alter type public.item_category add value if not exists 'personal_care' after 'household';

alter table public.items
  add column note text check (char_length(btrim(note)) between 1 and 80);

grant insert (note) on public.items to authenticated;
grant update (note) on public.items to authenticated;
