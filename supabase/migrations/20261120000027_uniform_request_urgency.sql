-- GiST enforces the invariant even across concurrent inserts into an empty case.
-- Deferred checking allows an atomic whole-case downgrade. Existing mixed cases
-- cause installation to fail rather than silently changing historical records.
create extension if not exists btree_gist with schema extensions;
alter table public.drawing_request_items
  add constraint uniform_request_urgency exclude using gist
    (request_id with =, is_urgent with <>)
  deferrable initially deferred;
