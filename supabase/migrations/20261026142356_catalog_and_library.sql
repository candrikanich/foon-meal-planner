-- Catalog and library (#5). The catalog is the shared, read-only starter pack we maintain;
-- the library is each household's own editable meals, items, and ingredient lines.
-- Meals archive and items persist; only ingredient lines on a meal can be removed (recipe edits).

create type public.meal_tag as enum (
  'quick', 'grill', 'slow_cooker', 'thaw_first', 'leftovers', 'backup', 'beginner'
);
create type public.meal_status as enum ('active', 'trial', 'archived', 'retired');
create type public.item_category as enum (
  'produce', 'meat_seafood', 'dairy_eggs', 'bakery', 'pantry', 'frozen', 'snacks', 'beverages', 'household', 'other'
);
create type public.stock_state as enum ('in', 'low', 'out');

-- Catalog -----------------------------------------------------------------------------------

create table public.catalog_meals (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null check (char_length(btrim(name)) between 1 and 80),
  category text not null check (char_length(btrim(category)) between 1 and 40),
  tags public.meal_tag[] not null default '{}',
  popular boolean not null default false,
  servings smallint not null default 4 check (servings between 1 and 50),
  prep_steps jsonb not null default '[]' check (jsonb_typeof(prep_steps) = 'array'),
  image_path text check (char_length(image_path) <= 512),
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.catalog_ingredients (
  id uuid primary key default gen_random_uuid(),
  catalog_meal_id uuid not null references public.catalog_meals (id),
  name text not null check (char_length(btrim(name)) between 1 and 60),
  category public.item_category not null default 'other',
  quantity_text text check (char_length(quantity_text) <= 60),
  position smallint not null default 0
);

create index catalog_ingredients_meal_idx on public.catalog_ingredients (catalog_meal_id, position);

-- Library -----------------------------------------------------------------------------------

create table public.items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  canonical_name text not null check (char_length(btrim(canonical_name)) between 1 and 60),
  -- One row per name so a pivot's "milk" and a tapped "Milk" merge on the list (see ensure_item).
  name_key text not null generated always as (lower(btrim(canonical_name))) stored,
  category public.item_category not null default 'other',
  keep_on_hand boolean not null default false,
  -- Only staples track stock; no counting, just in, low, or out.
  stock_state public.stock_state,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint items_stock_only_for_staples check (keep_on_hand = (stock_state is not null)),
  constraint items_id_household_key unique (id, household_id),
  constraint items_household_name_key unique (household_id, name_key)
);

create table public.meals (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  catalog_meal_id uuid references public.catalog_meals (id),
  name text not null check (char_length(btrim(name)) between 1 and 80),
  servings smallint not null default 4 check (servings between 1 and 50),
  tags public.meal_tag[] not null default '{}',
  prep_steps jsonb not null default '[]' check (jsonb_typeof(prep_steps) = 'array'),
  source_url text check (source_url ~* '^https?://' and char_length(source_url) <= 2048),
  photo_path text check (char_length(photo_path) <= 512),
  made_by_member_id uuid,
  status public.meal_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (made_by_member_id, household_id) references public.members (id, household_id),
  constraint meals_id_household_key unique (id, household_id)
);

create index meals_household_status_idx on public.meals (household_id, status);

create table public.meal_ingredients (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  meal_id uuid not null,
  item_id uuid not null,
  quantity_text text check (char_length(quantity_text) <= 60),
  position smallint not null default 0,
  foreign key (meal_id, household_id) references public.meals (id, household_id),
  foreign key (item_id, household_id) references public.items (id, household_id)
);

create index meal_ingredients_meal_idx on public.meal_ingredients (meal_id, position);
create index meal_ingredients_item_idx on public.meal_ingredients (item_id);

create trigger items_set_updated_at before update on public.items
  for each row execute function public.set_updated_at();
create trigger meals_set_updated_at before update on public.meals
  for each row execute function public.set_updated_at();

-- Grants ------------------------------------------------------------------------------------

revoke all on public.catalog_meals, public.catalog_ingredients,
              public.items, public.meals, public.meal_ingredients
  from anon, authenticated;

grant select on public.catalog_meals, public.catalog_ingredients to anon, authenticated;

grant select on public.items to authenticated;
grant insert (id, household_id, canonical_name, category, keep_on_hand, stock_state) on public.items to authenticated;
grant update (canonical_name, category, keep_on_hand, stock_state) on public.items to authenticated;

grant select on public.meals to authenticated;
grant insert (id, household_id, catalog_meal_id, name, servings, tags, prep_steps, source_url, photo_path,
              made_by_member_id, status) on public.meals to authenticated;
grant update (catalog_meal_id, name, servings, tags, prep_steps, source_url, photo_path, made_by_member_id, status)
  on public.meals to authenticated;

grant select, delete on public.meal_ingredients to authenticated;
grant insert (id, household_id, meal_id, item_id, quantity_text, position) on public.meal_ingredients to authenticated;
grant update (item_id, quantity_text, position) on public.meal_ingredients to authenticated;

-- Policies ----------------------------------------------------------------------------------

alter table public.catalog_meals enable row level security;
alter table public.catalog_ingredients enable row level security;
alter table public.items enable row level security;
alter table public.meals enable row level security;
alter table public.meal_ingredients enable row level security;

create policy "anyone reads the catalog" on public.catalog_meals
  for select to anon, authenticated using (true);
create policy "anyone reads catalog ingredients" on public.catalog_ingredients
  for select to anon, authenticated using (true);

-- Anyone at home can add an item or tap a staple low or out.
create policy "members read items" on public.items
  for select to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "members add items" on public.items
  for insert to authenticated
  with check (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "members update items" on public.items
  for update to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id))
  with check (public.is_household_member(household_id) or public.is_household_planner(household_id));

create policy "members read meals" on public.meals
  for select to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "planners add meals" on public.meals
  for insert to authenticated with check (public.is_household_planner(household_id));
create policy "planners edit meals" on public.meals
  for update to authenticated
  using (public.is_household_planner(household_id))
  with check (public.is_household_planner(household_id));

create policy "members read meal ingredients" on public.meal_ingredients
  for select to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "planners add meal ingredients" on public.meal_ingredients
  for insert to authenticated with check (public.is_household_planner(household_id));
create policy "planners edit meal ingredients" on public.meal_ingredients
  for update to authenticated
  using (public.is_household_planner(household_id))
  with check (public.is_household_planner(household_id));
create policy "planners remove meal ingredients" on public.meal_ingredients
  for delete to authenticated using (public.is_household_planner(household_id));

-- Item write guard --------------------------------------------------------------------------
-- Items are shared by every recipe that uses them, so only planners rename or recategorize.
-- Everyone else may change stock: mark a staple, tap it low or out.

create function public.items_guard_update()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if (select auth.uid()) is not null
     and not public.is_household_planner(old.household_id)
     and (new.canonical_name, new.category) is distinct from (old.canonical_name, old.category) then
    raise exception 'only planners rename or recategorize items' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger items_guard_update
  before update on public.items
  for each row execute function public.items_guard_update();

-- Find-or-create an item by name. Clients call this instead of a PostgREST upsert, which would
-- write every payload column back onto the existing row (household_id, stock state, ...).
-- The no-op update exists only so RETURNING yields the existing row; it runs under the caller's RLS.

create function public.ensure_item(
  target_household uuid,
  item_name text,
  item_category public.item_category default 'other'
)
returns public.items
language sql security invoker set search_path = ''
as $$
  insert into public.items as existing (household_id, canonical_name, category)
  values (target_household, btrim(item_name), item_category)
  on conflict (household_id, name_key) do update set canonical_name = existing.canonical_name
  returning *;
$$;

revoke execute on function public.ensure_item(uuid, text, public.item_category) from public, anon;
grant execute on function public.ensure_item(uuid, text, public.item_category) to authenticated;
