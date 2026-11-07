-- Erasing allergies erases the allergy notes on list lines too (#280).
--
-- The allergy consent (allergy-data-v2) promises that turning allergy alerts off erases them all. Deleting member_allergies
-- wasn't all: list lines keep allergy notes in note, kept_note and hand_note ("Get dairy-free (Nora, Owen)", "Can't have it
-- (Nora)", "Check: dairy, kiwi (Nora +2)"), built on the phone (WeeklyList) and saved by approve_plan, add_to_list and
-- move_to_quick_list.
--
-- A note is free text, merged from several sources and cut at 400, so the server can't reliably tell an allergy note from
-- anything else. Two rules, each safe in the direction that matters:
-- 1. Allergy alerts off: the household's line notes all go, and while they stay off no line keeps a note. That also stops
--    a phone whose cache or offline queue still holds an old note (a queued "Couldn't find it", a planner's Update the list
--    from before it heard) from writing it back. The one other note the app writes, "Couldn't find it last trip", goes too
--    in those households: a lost hint, never a kept allergy.
-- 2. One person's allergies all gone (an adult removing their own, a parent clearing them, delete_kid, an account deleted,
--    the retention job anonymizing a removed member): every note segment that names them goes, and the weeks whose lines
--    changed are marked list_stale so a planner's Update the list puts back what the others still need. Every allergy note
--    ends with who it's for in parentheses; WeeklyList keeps that, and its tests say so. A segment cut mid-name goes if the
--    name could be theirs. Changing some of someone's allergies, not all, leaves their notes until the next Update the list.

-- A line note without the segments naming this person.
create function public.list_note_without(note text, who text)
returns text
language sql immutable set search_path = ''
as $$
  select string_agg(part.segment, '; ' order by part.position)
  from unnest(string_to_array(note, '; ')) with ordinality as part(segment, position)
  where not exists (
    select 1
    from unnest(string_to_array(coalesce(substring(part.segment from '\(([^()]*)\)…?$'),
                                         substring(part.segment from '\(([^()]*)…$')), ', ')) as named(name),
         regexp_replace(named.name, ' \+[0-9]*$', '') as stripped(person)
    where stripped.person = who or (part.segment like '%…' and starts_with(who, stripped.person))
  );
$$;

revoke execute on function public.list_note_without(text, text) from public, anon, authenticated;

-- Rule 2. Runs from triggers, including the retention job's, where nobody is signed in.
create function public.forget_in_list_notes(target_household uuid, who text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if nullif(btrim(who), '') is null then
    return;
  end if;
  with changed as (
    update public.list_items
    set note = public.list_note_without(note, who),
        kept_note = public.list_note_without(kept_note, who),
        hand_note = public.list_note_without(hand_note, who)
    where household_id = target_household
      and position(who in concat(note, kept_note, hand_note)) > 0
      and (note, kept_note, hand_note) is distinct from (public.list_note_without(note, who),
                                                         public.list_note_without(kept_note, who),
                                                         public.list_note_without(hand_note, who))
    returning plan_id, also_for_plan, list
  )
  update public.plans set list_stale = true
  where household_id = target_household and approved_at is not null and not list_stale
    and id in (select plan_id from changed where list = 'weekly' union select also_for_plan from changed);
end;
$$;

revoke execute on function public.forget_in_list_notes(uuid, text) from public, anon, authenticated;

-- Rule 1.
create function public.erase_allergy_list_notes(target_household uuid)
returns void
language sql security definer set search_path = ''
as $$
  update public.list_items set note = null, kept_note = null, hand_note = null
  where household_id = target_household and (note is not null or kept_note is not null or hand_note is not null);
$$;

revoke execute on function public.erase_allergy_list_notes(uuid) from public, anon, authenticated;

-- For a function that removes allergies itself: the household's allergy notes (no member), or the ones naming a member.
-- The triggers below already cover every removal, so calling it is only needed for a path they don't see.
create function public.clear_allergy_list_notes(target_household uuid, target_member uuid default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_household_member(target_household) then
    raise exception 'not in this household' using errcode = '42501';
  end if;
  if target_member is null then
    perform public.erase_allergy_list_notes(target_household);
  else
    perform public.forget_in_list_notes(
      target_household,
      (select first_name from public.members where id = target_member and household_id = target_household));
  end if;
end;
$$;

revoke execute on function public.clear_allergy_list_notes(uuid, uuid) from public, anon;
grant execute on function public.clear_allergy_list_notes(uuid, uuid) to authenticated;

-- Allergy alerts off: its own trigger beside consents_erase_on_revoke, which deletes the allergies.
create function public.consents_erase_list_notes_on_revoke()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.kind = 'allergy_data' and new.member_id is null
     and old.revoked_at is null and new.revoked_at is not null then
    perform public.erase_allergy_list_notes(new.household_id);
  end if;
  return null;
end;
$$;

revoke execute on function public.consents_erase_list_notes_on_revoke() from public, anon, authenticated;

create trigger consents_erase_list_notes_on_revoke
  after update on public.consents
  for each row execute function public.consents_erase_list_notes_on_revoke();

-- While allergy alerts are off (agreed once, none active now), no line keeps a note. A family that never agreed has no
-- allergy notes to guard against, so its notes are left alone.
create function public.list_items_no_notes_while_allergies_off()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(new.note, new.kept_note, new.hand_note) is not null
     and exists (select 1 from public.consents
                 where household_id = new.household_id and kind = 'allergy_data' and member_id is null)
     and not exists (select 1 from public.consents
                     where household_id = new.household_id and kind = 'allergy_data' and member_id is null
                       and revoked_at is null) then
    new.note := null;
    new.kept_note := null;
    new.hand_note := null;
  end if;
  return new;
end;
$$;

revoke execute on function public.list_items_no_notes_while_allergies_off() from public, anon, authenticated;

create trigger list_items_no_notes_while_allergies_off
  before insert or update of note, kept_note, hand_note on public.list_items
  for each row execute function public.list_items_no_notes_while_allergies_off();

-- Someone's last allergy removed. Deferred to commit: set_member_allergies deletes everything and then adds back what a
-- parent kept, and only an empty result is a removal. By then delete_kid has deleted the profile and the retention job has
-- renamed it, so those go by the triggers on members below, which still see the name.
create function public.member_allergies_forget_list_notes()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.member_allergies where member_id = old.member_id) then
    perform public.forget_in_list_notes(old.household_id,
                                        (select first_name from public.members where id = old.member_id));
  end if;
  return null;
end;
$$;

revoke execute on function public.member_allergies_forget_list_notes() from public, anon, authenticated;

create constraint trigger member_allergies_forget_list_notes
  after delete on public.member_allergies
  deferrable initially deferred
  for each row execute function public.member_allergies_forget_list_notes();

-- A profile deleted (delete_kid) or anonymized ("Former member": an account deleted, or the retention job).
create function public.members_forget_list_notes()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.forget_in_list_notes(old.household_id, old.first_name);
  return null;
end;
$$;

revoke execute on function public.members_forget_list_notes() from public, anon, authenticated;

create trigger members_forget_list_notes_on_delete
  after delete on public.members
  for each row execute function public.members_forget_list_notes();

create trigger members_forget_list_notes_on_anonymize
  after update of first_name on public.members
  for each row when (new.first_name = 'Former member' and old.first_name is distinct from 'Former member')
  execute function public.members_forget_list_notes();

-- Households whose alerts are already off may still have notes from before.
update public.list_items set note = null, kept_note = null, hand_note = null
where (note is not null or kept_note is not null or hand_note is not null)
  and household_id in (select household_id from public.consents where kind = 'allergy_data' and member_id is null)
  and household_id not in (select household_id from public.consents
                           where kind = 'allergy_data' and member_id is null and revoked_at is null);
