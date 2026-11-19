create view public.v_work_requests with (security_invoker=true) as
select r.*, exists (
  select 1 from public.review_records v
  where v.request_id=r.id and v.round=r.round and v.level=1 and v.action='APPROVE'
    and v.is_effective and v.reviewer_id=app.current_employee_id()
) as approved_l1_by_me
from public.v_requests r;

-- Merge the existing detail sections before ordering and slicing a page.
create view public.v_case_timeline with (security_invoker=true) as
select request_id,'status-'||id as event_id,created_at as occurred_at,actor_id,
  'status'::text as kind,reason as note,jsonb_build_object('from',from_status,'to',to_status) as detail
from public.request_status_history
union all
select request_id,'review-'||id,created_at,reviewer_id,'review',comment,
  jsonb_build_object('round',round,'level',level,'action',action,'effective',is_effective,'principal',on_behalf_of_id)
from public.review_records
union all
select request_id,'revision-'||round,submitted_at,submitted_by,'resubmit',resubmit_note,jsonb_build_object('round',round)
from public.request_revisions where resubmit_note is not null
union all
select request_id,'claim-'||id,claimed_at,staff_id,'claim',null,null
from public.issue_claims
union all
select request_id,'release-'||id,released_at,released_by,'release',release_reason,jsonb_build_object('reassigned',reassigned_to)
from public.issue_claims where released_at is not null
union all
select request_id,'transfer-'||id,created_at,transferred_by,'transfer',reason,jsonb_build_object('from_owner',from_owner_id,'to_owner',to_owner_id)
from public.ownership_transfers;
revoke all on public.v_work_requests,public.v_case_timeline from public,anon,authenticated;
grant select on public.v_work_requests,public.v_case_timeline to authenticated;
