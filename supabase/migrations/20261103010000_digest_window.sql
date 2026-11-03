-- Q1: the Engaged new-ideas digest goes between 8:30 and 9pm on the household's clock, not from 7:30. Many families are
-- still at the table at 7:30; by 8:30 dinner has settled, and 9pm is still when quiet hours begin. The pg_cron job stays
-- every 15 minutes, so the window's runs are 8:30 and 8:45. Otherwise unchanged from 20261102220000_member_presets.

create or replace function public.enqueue_request_digests(at timestamptz default now())
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  queued int := 0;
  added int;
  house record;
begin
  for house in
    select h.id, public.household_time_zone(h.id) as tz from public.households h
    where exists (select 1 from public.members p
                  where p.household_id = h.id and p.role = 'planner' and p.status <> 'removed'
                    and public.member_preset(p.id) = 'engaged')
  loop
    if (at at time zone house.tz)::time < time '20:30' or (at at time zone house.tz)::time >= time '21:00'
       or public.household_away_on(house.id, (at at time zone house.tz)::date) then
      continue;
    end if;

    insert into public.push_outbox
      (household_id, member_id, kind, about_member_id, args, not_before, expires_at, created_at)
    select house.id, m.id, 'new_requests', named.id,
           jsonb_build_object('count', news.count)
             || case when named.id is not null then jsonb_build_object('name', named.first_name) else '{}' end,
           public.push_not_before(house.tz, m.age_group = 'kid', at),
           ((at at time zone house.tz)::date + time '21:00') at time zone house.tz,
           at
    from public.members m
    cross join lateral (
      select coalesce(max(o.created_at), at - interval '1 day') as since
      from public.push_outbox o where o.member_id = m.id and o.kind = 'new_requests'
    ) last_digest
    cross join lateral (
      select count(*)::int as count,
             case when count(distinct r.requested_by_member_id) = 1 then min(r.requested_by_member_id::text)::uuid end
               as only_one
      from public.requests r
      where r.household_id = house.id and r.status = 'open'
        and r.created_at > greatest(last_digest.since, at - interval '1 day') and r.created_at <= at
        and r.requested_by_member_id <> m.id and r.entered_by_member_id is distinct from m.id
        -- Someone removed isn't asking any more, and their name mustn't go out.
        and exists (select 1 from public.members asker
                    where asker.id = r.requested_by_member_id and asker.status <> 'removed')
    ) news
    left join public.members named on named.id = news.only_one and public.push_may_name(named.id)
    where m.household_id = house.id and m.role = 'planner' and m.status <> 'removed'
      and public.member_preset(m.id) = 'engaged'
      and news.count > 0
      and exists (select 1 from public.push_devices d where d.member_id = m.id)
      and not exists (select 1 from public.push_outbox o
                      where o.member_id = m.id and o.kind = 'new_requests'
                        and (o.created_at at time zone house.tz)::date = (at at time zone house.tz)::date);
    get diagnostics added = row_count;
    queued := queued + added;
  end loop;
  return queued;
end;
$$;

revoke execute on function public.enqueue_request_digests(timestamptz) from public, anon, authenticated;
