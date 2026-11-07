-- Erasing allergies erases the allergy notes on list lines too (#280). Allergy alerts off clears the household's line notes
-- and keeps new ones off; someone's allergies all gone (their own removal, delete_kid, the retention job) takes the note
-- segments naming them (or, if they had allergies, a "+2" or cut one) and marks their weeks for Update the list. A parent's
-- edit keeps them; removing someone without allergies keeps grouped warnings; other households are untouched.
begin;
select plan(36);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;
create function pg_temp.line(id uuid) returns public.list_items language sql as $$
  select * from public.list_items where list_items.id = line.id;
$$;

-- Household A: Ann (owner, parent), Grace and Hal (adults who aren't parents; Grace signed in), Ivy (a kid without an
-- account), Kay (a kid without an account or allergies), Jo (an adult without allergies). Household B: Carol (owner) and Dan (signed in). Household C: Eve, who never turned allergy alerts on.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'grace@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'dan@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'eve@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000c0', 'Evanses', 'e0000000-0000-0000-0000-00000000000e');
insert into public.members (id, household_id, first_name, role, age_group, guardian, status, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true, 'active', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'member', 'adult', false, 'active', 'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Hal', 'member', 'adult', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Ivy', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Kay', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Jo', 'member', 'adult', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true, 'active', 'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b0', 'Dan', 'member', 'adult', false, 'active', 'f0000000-0000-0000-0000-00000000000f'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c0', 'Eve', 'planner', 'adult', true, 'active', 'e0000000-0000-0000-0000-00000000000e');
insert into public.consents (household_id, member_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', null, 'allergy_data', 'a0000000-0000-0000-0000-00000000000a', 'allergy-data-v2'),
  ('00000000-0000-0000-0000-0000000000b0', null, 'allergy_data', 'c0000000-0000-0000-0000-00000000000c', 'allergy-data-v2');
insert into public.member_allergies (household_id, member_id, category, custom_text) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'wheat', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'milk', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'custom', 'kiwi'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'soy', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'milk', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'eggs', null),
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000b2', 'eggs', null);

insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0', '2026-11-08');
update public.plans set approved_at = now() where id = '00000000-0000-0000-0000-0000000003a1';
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Cheese'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Eggs'),
  ('00000000-0000-0000-0000-0000000001a3', '00000000-0000-0000-0000-0000000000a0', 'Smoothie mix'),
  ('00000000-0000-0000-0000-0000000001a4', '00000000-0000-0000-0000-0000000000a0', 'Bread'),
  ('00000000-0000-0000-0000-0000000001a5', '00000000-0000-0000-0000-0000000000a0', 'Soy sauce'),
  ('00000000-0000-0000-0000-0000000001a6', '00000000-0000-0000-0000-0000000000a0', 'Milk'),
  ('00000000-0000-0000-0000-0000000001a7', '00000000-0000-0000-0000-0000000000a0', 'Pancake mix'),
  ('00000000-0000-0000-0000-0000000001b1', '00000000-0000-0000-0000-0000000000b0', 'Eggs'),
  ('00000000-0000-0000-0000-0000000001c1', '00000000-0000-0000-0000-0000000000c0', 'Milk');
insert into public.list_items (id, household_id, item_id, list, source, plan_id, note, kept_note, hand_note) values
  ('00000000-0000-0000-0000-0000000008a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1',
   'weekly', 'plan', '00000000-0000-0000-0000-0000000003a1',
   'Get dairy-free (Grace, Ivy); Couldn''t find it last trip', 'Get dairy-free (Grace, Ivy)', null),
  ('00000000-0000-0000-0000-0000000008a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2',
   'quick', 'pivot', null, 'Can''t have it (Ivy)', 'Can''t have it (Ivy)', 'Can''t have it (Ivy)'),
  ('00000000-0000-0000-0000-0000000008a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a3',
   'quick', 'pivot', null, 'Check: dairy, kiwi (Grace +2)', null, null),
  ('00000000-0000-0000-0000-0000000008a4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a4',
   'weekly', 'plan', '00000000-0000-0000-0000-0000000003a1', 'Get gluten-free (Ann)', null, null),
  ('00000000-0000-0000-0000-0000000008a5', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a5',
   'quick', 'pivot', null, 'Get soy-free (Hal)', null, null),
  -- Cut at the limit mid-name: merge_line_notes keeps the newest and ends with "…".
  ('00000000-0000-0000-0000-0000000008a6', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a7',
   'quick', 'pivot', null, 'Get gluten-free (Ann); Get egg-free (Ann, Iv…', null, null),
  ('00000000-0000-0000-0000-0000000008b1', '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000001b1',
   'quick', 'pivot', null, 'Get egg-free (Dan)', null, null);
-- One bought, still in the history.
update public.list_items set checked_at = now() where id = '00000000-0000-0000-0000-0000000008a3';

-- Which segments name someone ----------------------------------------------------------------------------------------
select is(public.list_note_without('Get dairy-free (Grace, Ivy); Couldn''t find it last trip', 'Grace'),
  'Couldn''t find it last trip', 'a segment naming them goes, the rest stays');
select is(public.list_note_without('Check: dairy, kiwi (Grace +2)', 'Grace'), null, 'a compact note naming them goes');
select is(public.list_note_without('Check: dairy, kiwi (Grace +2)', 'Ivy', true), null,
  'so does one whose "+2" could be them, for someone who had allergies');
select is(public.list_note_without('Check: dairy, kiwi (Grace +2)', 'Ivy'), 'Check: dairy, kiwi (Grace +2)',
  'but not for someone who had none');
select is(public.list_note_without('Get dairy-free (Grace, Ivy)', 'Ann', true), 'Get dairy-free (Grace, Ivy)',
  'one that names others and not them stays');
select is(public.list_note_without('Can''t have it (Ann)', 'An'), 'Can''t have it (Ann)',
  'a name is a whole name, not the start of one');
select is(public.list_note_without('Get soy-free (Hal); Get egg-free (Nora, Ow…', 'Zed', true), 'Get soy-free (Hal)',
  'a segment cut inside its parentheses goes, for someone who had allergies');
select is(public.list_note_without('Check for nuts (all kinds) (Nora)', 'Nora'), null,
  'the names are the last parentheses');

-- A parent's edit isn't a removal --------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select public.set_member_allergies('00000000-0000-0000-0000-0000000000a5', '{milk,eggs,soy}', '{}');
set constraints public.member_allergies_forget_list_notes immediate;
set constraints public.member_allergies_forget_list_notes deferred;
select pg_temp.as_admin();
select is((pg_temp.line('00000000-0000-0000-0000-0000000008a2')).note, 'Can''t have it (Ivy)',
  'a parent changing a kid''s allergies keeps their notes');
select is((select list_stale from public.plans where id = '00000000-0000-0000-0000-0000000003a1'), false,
  'and leaves the list as it was');

-- Someone with no allergies deleted or anonymized: the family's grouped warnings stay -------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select public.delete_kid('00000000-0000-0000-0000-0000000000a6');
select pg_temp.as_admin();
select is((pg_temp.line('00000000-0000-0000-0000-0000000008a3')).note, 'Check: dairy, kiwi (Grace +2)',
  'deleting a kid who had no allergies keeps a "+2" warning');
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a7';
update public.members set removed_at = now() - interval '13 months' where id = '00000000-0000-0000-0000-0000000000a7';
select public.anonymize_expired_profiles();
select is((select first_name from public.members where id = '00000000-0000-0000-0000-0000000000a7'), 'Former member',
  'the retention job anonymizes Jo');
select is((pg_temp.line('00000000-0000-0000-0000-0000000008a3')).note, 'Check: dairy, kiwi (Grace +2)',
  'and the "+2" warning stays');
select is((pg_temp.line('00000000-0000-0000-0000-0000000008a6')).note, 'Get gluten-free (Ann); Get egg-free (Ann, Iv…',
  'as does a note cut inside its parentheses');

-- An adult removes their own -------------------------------------------------------------------------------------------
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Grace
select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2', '{}', '{}');
set constraints public.member_allergies_forget_list_notes immediate;
set constraints public.member_allergies_forget_list_notes deferred;
select pg_temp.as_admin();
select is((pg_temp.line('00000000-0000-0000-0000-0000000008a1')).note, 'Couldn''t find it last trip',
  'removing your own allergies takes the notes naming you');
select is((pg_temp.line('00000000-0000-0000-0000-0000000008a1')).kept_note, null, 'from every note column');
select is((pg_temp.line('00000000-0000-0000-0000-0000000008a3')).note, null, 'and from bought lines, "+2" ones too');
select is((pg_temp.line('00000000-0000-0000-0000-0000000008a6')).note, 'Get gluten-free (Ann)',
  'a part cut inside its parentheses goes too');
select is((pg_temp.line('00000000-0000-0000-0000-0000000008a4')).note, 'Get gluten-free (Ann)', 'others'' notes stay');
select is((select list_stale from public.plans where id = '00000000-0000-0000-0000-0000000003a1'), true,
  'and the week asks for Update the list, to put back what Ivy still needs');

-- delete_kid ------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select public.delete_kid('00000000-0000-0000-0000-0000000000a5');
select pg_temp.as_admin();
select is((pg_temp.line('00000000-0000-0000-0000-0000000008a2')).note, null, 'deleting a kid takes the notes naming them');
select is((pg_temp.line('00000000-0000-0000-0000-0000000008a2')).hand_note, null, 'every column');

-- The retention job anonymizing a removed adult ------------------------------------------------------------------------
-- Two steps: removing stamps removed_at with now, so the date is set back after.
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a3';
update public.members set removed_at = now() - interval '13 months' where id = '00000000-0000-0000-0000-0000000000a3';
select is((select count(*)::int from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a3'), 1,
  'Hal is removed a year ago, allergies still kept');
select public.anonymize_expired_profiles();
select is((pg_temp.line('00000000-0000-0000-0000-0000000008a5')).note, null,
  'anonymizing a removed adult takes the notes naming them');

-- Allergy alerts off ---------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select public.revoke_allergy_consent('00000000-0000-0000-0000-0000000000a0');
select pg_temp.as_admin();
select is((select count(*)::int from public.list_items
           where household_id = '00000000-0000-0000-0000-0000000000a0'
             and (note is not null or kept_note is not null or hand_note is not null)), 0,
  'turning allergy alerts off clears every line note in the household');
select is((pg_temp.line('00000000-0000-0000-0000-0000000008b1')).note, 'Get egg-free (Dan)',
  'another household''s notes stay');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select is((public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a6', 'quick',
                              'whenever', 'manual', 'Can''t have it (Ann)')).note, null,
  'while they''re off, a stale phone can''t write a note back');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a4", "quantity": null, "note": "Get gluten-free (Ann)", "staple": false}]');
select is((select note from public.list_items where id = '00000000-0000-0000-0000-0000000008a4'), null,
  'nor a planner''s list from before it heard');
update public.list_items set note = 'Get gluten-free (Ann)' where id = '00000000-0000-0000-0000-0000000008a4';
select is((select note from public.list_items where id = '00000000-0000-0000-0000-0000000008a4'), null,
  'nor a direct write');

-- On again: notes are kept again
select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v2');
update public.list_items set note = 'Get gluten-free (Ann)' where id = '00000000-0000-0000-0000-0000000008a4';
select is((select note from public.list_items where id = '00000000-0000-0000-0000-0000000008a4'), 'Get gluten-free (Ann)',
  'once a parent agrees again, notes are kept again');

-- A family that never turned them on keeps its notes
select pg_temp.as_admin();
insert into public.list_items (household_id, item_id, list, note) values
  ('00000000-0000-0000-0000-0000000000c0', '00000000-0000-0000-0000-0000000001c1', 'quick', 'Couldn''t find it last trip');
select is((select note from public.list_items where household_id = '00000000-0000-0000-0000-0000000000c0'),
  'Couldn''t find it last trip', 'a family that never agreed keeps its notes');

-- Who may call what ----------------------------------------------------------------------------------------------------
select ok(not has_function_privilege('authenticated', 'public.forget_in_list_notes(uuid, text, boolean)', 'execute'),
  'nobody signed in calls the unchecked helpers');
select ok(not has_function_privilege('authenticated', 'public.erase_allergy_list_notes(uuid)', 'execute'), 'either one');
select ok(not exists (select 1 from pg_proc where proname = 'clear_allergy_list_notes'),
  'and there''s no clearing function a member could call to strip the family''s allergy warnings');
select ok(not has_function_privilege('authenticated', 'public.list_note_without(text, text, boolean)', 'execute'),
  'or the note helper');
select ok(not has_function_privilege('authenticated', 'public.member_allergies_note_removal()', 'execute'),
  'or the trigger that records whose allergies were removed');

select * from finish();
rollback;
