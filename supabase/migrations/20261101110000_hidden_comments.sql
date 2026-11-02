-- Hidden comments are really hidden (#149), now that the after-dinner card writes comments. Row-level security can't hide
-- one column of one row, so a hidden comment's text moves out of reactions, which the whole family can read, into a table
-- only planners can. Nothing's deleted: showing it again moves the text back.
--
-- Everything that clears or erases a comment keeps working unchanged. Setting reactions.comment to null clears a hidden
-- comment's text too (the trigger), and deleting a reaction takes its hidden row with it (the cascade). So retention,
-- deleting an account and deleting a household need no new code, here or in any later copy of those functions.

create table public.hidden_comments (
  reaction_id uuid primary key references public.reactions (id) on delete cascade,
  household_id uuid not null references public.households (id),
  -- Null once its text is cleared. The row stays, so what's written next is still hidden.
  comment text check (char_length(btrim(comment)) between 1 and 140),
  hidden_at timestamptz not null default now()
);

create index hidden_comments_household_idx on public.hidden_comments (household_id);

-- Only set_comment_hidden and the trigger below write here.
revoke all on public.hidden_comments from anon, authenticated;
grant select on public.hidden_comments to authenticated;

alter table public.hidden_comments enable row level security;

create policy "planners read hidden comments" on public.hidden_comments
  for select to authenticated using (public.is_household_planner(household_id));

insert into public.hidden_comments (reaction_id, household_id, comment, hidden_at)
  select id, household_id, comment, comment_hidden_at from public.reactions
  where comment_hidden_at is not null and comment is not null;
update public.reactions set comment = null where comment_hidden_at is not null;

-- A row in hidden_comments is what hidden means now, and the old column would tell the family which comments were hidden.
drop view public.meal_comments;
alter table public.reactions drop column comment_hidden_at;

-- The same columns as before. Hidden text comes through the join, so only planners get it, through that table's own policy.
create view public.meal_comments
with (security_invoker = true)
as
  select r.id, r.household_id, l.meal_id, r.member_id, coalesce(h.comment, r.comment) as comment, n.date as dinner_on,
         h.reaction_id is not null as hidden
  from public.reactions r
  join public.meal_logs l on l.id = r.meal_log_id
  join public.plan_nights n on n.id = l.night_id
  join public.members m on m.id = r.member_id
  left join public.hidden_comments h on h.reaction_id = r.id
  where coalesce(h.comment, r.comment) is not null and l.meal_id is not null and m.status <> 'removed'
    and not m.eats_separately;

revoke all on public.meal_comments from anon, authenticated;
grant select on public.meal_comments to authenticated;

-- Writing a comment that's hidden: new words stay hidden, so changing it doesn't publish it, and null clears the words but
-- not the hiding, so clearing it and writing again doesn't publish it either. Fires only when an update names the comment column, so changing a rating leaves hidden text alone.
create function public.reactions_keep_comment_hidden()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.hidden_comments set comment = new.comment where reaction_id = new.id;
  if found then
    new.comment := null;
  end if;
  return new;
end;
$$;

revoke execute on function public.reactions_keep_comment_hidden() from public, anon, authenticated;

create trigger reactions_keep_comment_hidden before update of comment on public.reactions
  for each row execute function public.reactions_keep_comment_hidden();

-- Security definer: the author's columns are the only ones the table lets a person write, and this leaves them alone
-- (reactions_guard would otherwise record the planner as whoever entered the rating). The column is cleared before the
-- hidden row exists, and restored after it's gone, so the trigger above has nothing to do.
create or replace function public.set_comment_hidden(target_reaction uuid, hide boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  household uuid;
  words text;
begin
  select household_id, comment into household, words from public.reactions
  where id = target_reaction and public.is_household_member(household_id)
  for update;
  if household is null then
    raise exception 'no comment %', target_reaction using errcode = 'P0002';
  end if;
  if not public.is_household_planner(household) then
    raise exception 'only planners hide comments' using errcode = '42501';
  end if;
  if hide then
    if words is not null then
      update public.reactions set comment = null where id = target_reaction;
      insert into public.hidden_comments (reaction_id, household_id, comment) values (target_reaction, household, words);
    end if;
  else
    delete from public.hidden_comments where reaction_id = target_reaction returning comment into words;
    if found then
      update public.reactions set comment = words where id = target_reaction;
    end if;
  end if;
end;
$$;

-- The export is a planner's, so it has the hidden text, in its own section.
create or replace function public.export_household(target_household uuid)
returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners export the household' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'exported_at', now(),
    'household', (select to_jsonb(h) - 'owner' from public.households h where id = target_household),
    'members', (select coalesce(jsonb_agg(to_jsonb(m) - 'user_id' - 'household_id' order by m.created_at), '[]')
                from public.members m where household_id = target_household),
    'allergies', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id'), '[]')
                  from public.member_allergies a where household_id = target_household),
    'consents', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' - 'granted_by' order by c.granted_at), '[]')
                 from public.consents c where household_id = target_household),
    'consent_agreements', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id' - 'agreed_by' order by a.agreed_at), '[]')
                           from public.consent_agreements a where household_id = target_household),
    'meals', (select coalesce(jsonb_agg(to_jsonb(m) - 'household_id' order by m.name), '[]')
              from public.meals m where household_id = target_household),
    'meal_ingredients', (select coalesce(jsonb_agg(to_jsonb(i) - 'household_id'), '[]')
                         from public.meal_ingredients i where household_id = target_household),
    'meal_sides', (select coalesce(jsonb_agg(to_jsonb(s) - 'household_id'), '[]')
                   from public.meal_sides s where household_id = target_household),
    'items', (select coalesce(jsonb_agg(to_jsonb(i) - 'household_id' order by i.canonical_name), '[]')
              from public.items i where household_id = target_household),
    'traditions', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id'), '[]')
                   from public.traditions t where household_id = target_household),
    'plans', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.week_start), '[]')
              from public.plans p where household_id = target_household),
    'nights', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.date), '[]')
               from public.plan_nights n where household_id = target_household),
    'attendance', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id'), '[]')
                   from public.night_attendance a where household_id = target_household),
    'list_items', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id'), '[]')
                   from public.list_items l where household_id = target_household),
    'meal_logs', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id' order by l.created_at), '[]')
                  from public.meal_logs l where household_id = target_household),
    'reactions', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                  from public.reactions r where household_id = target_household),
    'hidden_comments', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.hidden_at), '[]')
                        from public.hidden_comments c where household_id = target_household),
    'chef_thanks', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                    from public.chef_thanks t where household_id = target_household),
    'serving_notes', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.created_at), '[]')
                      from public.serving_notes n where household_id = target_household),
    'requests', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                 from public.requests r where household_id = target_household),
    'request_plus_ones', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.created_at), '[]')
                          from public.request_plus_ones p where household_id = target_household),
    'attendance_templates', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                             from public.attendance_templates t where household_id = target_household),
    'freezer_stash', (select coalesce(jsonb_agg(to_jsonb(f) - 'household_id' order by f.created_at), '[]')
                      from public.freezer_stash f where household_id = target_household),
    'night_claims', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.created_at), '[]')
                     from public.night_claims c where household_id = target_household),
    'plan_changes', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.id), '[]')
                     from public.plan_changes c where household_id = target_household),
    'notification_log', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id' order by l.created_at), '[]')
                         from public.notification_log l where household_id = target_household)
  );
end;
$$;
