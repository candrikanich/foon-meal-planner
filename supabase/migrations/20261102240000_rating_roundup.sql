-- The weekly rating roundup (#47, ignore handling): a phone that's stopped getting answers to each night's after-dinner
-- prompt asks once a week instead, and logs it like any reminder. record_notifications drops a type the log doesn't know, so
-- it's added here. Push keeps the same list as the log, so what's sent can be logged.

alter table public.notification_log drop constraint notification_log_type_check;
alter table public.notification_log add constraint notification_log_type_check check (type in (
  'time_to_plan', 'prep_reminder', 'after_dinner', 'day_of_check_in', 'requests_open', 'plan_set', 'no_plan_tonight',
  'tonight_poll', 'urgent_item', 'new_requests', 'weekly_recap', 'claim', 'request_planned', 'heading_to_store',
  'not_home', 'rating_roundup'));

alter table public.push_outbox drop constraint push_outbox_kind_check;
alter table public.push_outbox add constraint push_outbox_kind_check check (kind in (
  'time_to_plan', 'prep_reminder', 'after_dinner', 'day_of_check_in', 'requests_open', 'plan_set', 'no_plan_tonight',
  'tonight_poll', 'urgent_item', 'new_requests', 'weekly_recap', 'claim', 'request_planned', 'heading_to_store',
  'not_home', 'rating_roundup'));
