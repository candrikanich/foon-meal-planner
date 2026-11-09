-- #277: a kid needing a parent's OK is outside the weekly push budget, like Plan's set and urgent items.
begin;
select plan(4);

select ok(public.push_outside_budget('agreement_hold'), 'a held kid''s push always goes and uses none of the budget');
select ok(public.push_outside_budget('plan_set'), 'Plan''s set still sits outside it');
select ok(public.push_outside_budget('urgent_item'), 'and urgent items');
select ok(not public.push_outside_budget('heading_to_store'), 'everything else still counts');

select * from finish();
rollback;
