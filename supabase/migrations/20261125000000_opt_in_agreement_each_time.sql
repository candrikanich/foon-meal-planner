-- Opt-in email (#48): every time an adult turns an email on, Foon logs a new agreement, even to a wording they agreed to
-- before (Chris, 2026-11-11). Turning it off and on again is a fresh yes, so it gets its own row and time.
--
-- Terms and Privacy keep one row per account per wording: accepting the same wording again (next launch) logs nothing.
-- So the uniqueness on (user_id, text_version) now covers those two kinds only, and accept_agreements names the same
-- predicate so Postgres can still match its on conflict to the index. set_email_preference drops its on conflict.

alter table public.account_agreements drop constraint account_agreements_user_id_text_version_key;
create unique index account_agreements_once_per_wording on public.account_agreements (user_id, text_version)
  where kind in ('terms', 'privacy');

-- As in 20261117000000_agreements.sql, with the index's predicate on the on conflict.
create or replace function public.accept_agreements(terms text, privacy text, context text, client text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
begin
  if caller is null or not public.session_is_active() then
    raise exception 'sign in first' using errcode = '28000';
  end if;
  if not exists (select 1 from public.agreement_versions where version = terms and kind = 'terms')
     or not exists (select 1 from public.agreement_versions where version = privacy and kind = 'privacy') then
    raise exception 'unknown wording' using errcode = '22023';
  end if;
  if context is null or context not in ('create_household', 'join', 'next_launch', 'changed') then
    raise exception 'context is create_household, join, next_launch or changed' using errcode = '22023';
  end if;
  if char_length(client) > 40 then
    raise exception 'client is at most 40 characters' using errcode = '22023';
  end if;
  insert into public.account_agreements (user_id, kind, text_version, context, client)
  values (caller, 'terms', terms, context, client), (caller, 'privacy', privacy, context, client)
  on conflict (user_id, text_version) where kind in ('terms', 'privacy') do nothing;
end;
$$;

revoke execute on function public.accept_agreements(text, text, text, text) from public, anon;
grant execute on function public.accept_agreements(text, text, text, text) to authenticated;

-- As in 20261124000000_account_email_opt_in.sql, except turning one on always logs a new agreement row.
create or replace function public.set_email_preference(email_kind text, enabled boolean, wording text default null,
                                                       client text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
  agreement public.agreement_kind;
begin
  if caller is null or not public.session_is_active() then
    raise exception 'sign in first' using errcode = '28000';
  end if;
  agreement := case email_kind
    when 'weekly_plan' then 'weekly_plan_email'::public.agreement_kind
    when 'founding_updates' then 'founding_updates'::public.agreement_kind
  end;
  if agreement is null or enabled is null then
    raise exception 'email_kind is weekly_plan or founding_updates, and enabled is true or false' using errcode = '22023';
  end if;
  if char_length(client) > 40 then
    raise exception 'client is at most 40 characters' using errcode = '22023';
  end if;

  if enabled then
    if public.email_opt_in_household(caller) is null then
      raise exception 'only adults in a household get email' using errcode = '42501', hint = 'adults_only';
    end if;
    if not coalesce((select c.account_email_enabled from public.app_config c), false) then
      raise exception 'Foon doesn''t send email yet' using errcode = '55000', hint = 'email_off';
    end if;
    if wording is null
       or not exists (select 1 from public.agreement_versions v where v.version = wording and v.kind = agreement) then
      raise exception 'unknown wording' using errcode = '22023';
    end if;
    insert into public.account_agreements (user_id, kind, text_version, context, client)
    values (caller, agreement, wording, 'opt_in', client);
  end if;

  if enabled then
    insert into public.email_preferences (user_id) values (caller) on conflict (user_id) do nothing;
  end if;
  -- Turning one on again records the latest agreement; turning off what was never on writes nothing.
  if email_kind = 'weekly_plan' then
    update public.email_preferences
       set weekly_plan = enabled,
           weekly_plan_version = case when enabled then wording end,
           weekly_plan_agreed_at = case when enabled then now() end,
           updated_at = now()
     where user_id = caller;
  else
    update public.email_preferences
       set founding_updates = enabled,
           founding_updates_version = case when enabled then wording end,
           founding_updates_agreed_at = case when enabled then now() end,
           updated_at = now()
     where user_id = caller;
  end if;
  return public.my_email_preferences();
end;
$$;

revoke execute on function public.set_email_preference(text, boolean, text, text) from public, anon;
grant execute on function public.set_email_preference(text, boolean, text, text) to authenticated;
