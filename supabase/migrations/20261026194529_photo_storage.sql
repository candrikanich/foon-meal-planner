-- Photo storage (#13). Family photos are never public: a private bucket, one folder per household
-- (`<household_id>/meals/<uuid>.jpg`), members read their household's folder and planners write it
-- (matching who edits meals). The app strips metadata and re-encodes to JPEG before upload, and
-- shows images only through short-lived signed URLs.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('household-photos', 'household-photos', false, 5242880, '{image/jpeg}');

-- The household that owns an object, from its first folder; null for anything else.
create function public.storage_household(object_name text)
returns uuid
language sql immutable set search_path = ''
as $$
  select case
    when (storage.foldername(object_name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then ((storage.foldername(object_name))[1])::uuid
  end;
$$;

-- The helpers carry the session check from #14, so signed-out sessions get nothing here either.
create policy "household members read their photos" on storage.objects
  for select to authenticated
  using (bucket_id = 'household-photos'
         and (public.is_household_member(public.storage_household(name))
              or public.is_household_planner(public.storage_household(name))));

create policy "planners add household photos" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'household-photos' and public.is_household_planner(public.storage_household(name)));

create policy "planners replace household photos" on storage.objects
  for update to authenticated
  using (bucket_id = 'household-photos' and public.is_household_planner(public.storage_household(name)))
  with check (bucket_id = 'household-photos' and public.is_household_planner(public.storage_household(name)));

create policy "planners remove household photos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'household-photos' and public.is_household_planner(public.storage_household(name)));

-- A meal can only point at a photo in its own household's folder.
alter table public.meals
  add constraint meals_photo_in_household_folder
  check (photo_path is null or photo_path like household_id::text || '/%');
