-- The seeded starter catalog (#10, supabase/seed/catalog.sql) matches docs/starter-pack.md's shape.
begin;
select plan(9);

select is((select count(*)::int from public.catalog_meals), 69, 'all 69 starter dishes are seeded');
select is((select count(distinct category)::int from public.catalog_meals), 12, 'dishes span the 12 categories');
select is((select count(*)::int from public.catalog_meals where popular), 42, 'popular dishes match the starter pack');
select is_empty(
  $$ select slug from public.catalog_meals m
     where not exists (select 1 from public.catalog_ingredients i where i.catalog_meal_id = m.id) $$,
  'every dish has ingredients');
select is_empty(
  $$ select slug from public.catalog_meals where image_path is distinct from 'catalog/' || slug || '.jpg' $$,
  'every dish has a placeholder image path');
select is_empty(
  $$ select slug from public.catalog_meals where servings not between 4 and 8 $$,
  'default servings fit a family');
select is_empty(
  $$ select slug from public.catalog_meals
     where ('thaw_first' = any (tags)) <> (prep_steps @> '[{"lead_hours": 24}]') $$,
  'thaw-first dishes, and only they, carry a 24-hour thaw step');
select is_empty(
  $$ select slug from public.catalog_meals
     where ('slow_cooker' = any (tags)) <> (prep_steps @> '[{"lead_hours": 8}]') $$,
  'slow-cooker dishes, and only they, carry an 8-hour start step');
select is_empty(
  $$ select slug from public.catalog_meals where ('backup' = any (tags)) <> (category = 'Freezer and backup') $$,
  'backup dinners are exactly the freezer-and-backup category');

select * from finish();
rollback;
