-- Founding families (#37). While founding is open (the internal and external TestFlight betas), every new
-- household is flagged founding = true: free during the beta, then the Founding Family price
-- (docs/app-store-submission.md). At launch, a migration sets founding_open = false; flagged households keep it.
-- The switch is server-only: clients can't read it, flip it, or set the flag themselves.

create table public.app_config (
  id boolean primary key default true check (id),
  founding_open boolean not null default true
);
insert into public.app_config default values;

alter table public.app_config enable row level security;
revoke all on public.app_config from public, anon, authenticated;

create function public.set_founding()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.founding := coalesce((select founding_open from public.app_config), false);
  return new;
end;
$$;
revoke execute on function public.set_founding() from public, anon, authenticated;

create trigger households_founding
  before insert on public.households
  for each row execute function public.set_founding();
