"""Focused replay/concurrency checks against the isolated local API bridge."""
import json
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, ProxyHandler, build_opener
from uuid import uuid4

BASE = "http://127.0.0.1:54329"
passwords = json.loads(Path(os.environ["SUCOOT_LOCAL_ACCOUNTS"]).read_text())


def post(path, body, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = Request(BASE + path, json.dumps(body).encode(), headers)
    try:
        with build_opener(ProxyHandler({})).open(req, timeout=20) as response:
            content = response.read()
            return json.loads(content) if content else None
    except HTTPError as error:
        raise RuntimeError(json.load(error).get("message", str(error.code))) from None


def login(name):
    return post("/auth/v1/token?grant_type=password", {
        "email": name.lower()+"@login.sucoot.com", "password": passwords[name],
    })["access_token"]


def rpc(token, name, **args):
    return post("/rest/v1/rpc/"+name, args, token)


def prepare(token, action, args):
    key = str(uuid4())
    rpc(token, "prepare_operation", p_key=key, p_action=action, p_args=args)
    return key


def execute(token, key):
    return rpc(token, "execute_operation", p_key=key)


def race(jobs):
    def run(job):
        try:
            return execute(*job)
        except RuntimeError as error:
            if "IN_PROGRESS" not in str(error):
                raise
            return None
    with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
        return list(pool.map(run, jobs))


applicant, manager, drawing, staff, admin = map(login, ["TEST001","TEST003","TEST004","TEST005","admin"])
application = dict(p_id=None,p_version=None,p_purpose="冪等驗證",p_urgent=False,p_reason=None,
                   p_note=None,p_products=[dict(code="P1-TEST",name="測試品")],p_submit=True)
key = prepare(applicant,"write_r8_application",application)
race([(applicant,key)]*2)
# Discard the first HTTP result. A fresh login must recover the committed case.
applicant = login("TEST001")
stored = next(x for x in rpc(applicant,"operation_results",p_keys=[key]) if x["id"]==key)
original = execute(applicant,key)
assert stored["result"] == original and original["ok"]
case = original["id"]
for token, args in [(manager,application),(applicant,{**application,"p_note":"不同內容"})]:
    try:
        rpc(token,"prepare_operation",p_key=key,p_action="write_r8_application",p_args=args)
    except RuntimeError as e:
        assert "OPERATION_CONFLICT" in str(e)
    else:
        raise AssertionError("Rebound operation key")
assert all(row["id"]!=key for row in rpc(manager,"operation_results",p_keys=[key]))
rpc(applicant,"ack_operation_results",p_keys=[key])
assert all(row["id"]!=key for row in rpc(applicant,"operation_results"))
assert execute(applicant,key)==original


def version(token):
    req = Request(BASE+"/rest/v1/v_requests?select=version&id=eq."+case,
                  headers={"Authorization":"Bearer "+token})
    with build_opener(ProxyHandler({})).open(req) as response:
        return json.load(response)[0]["version"]


def action(token, name, **fields):
    args=dict(p_id=case,p_expected_version=version(token),**fields)
    ident=prepare(token,name,args)
    result=execute(token,ident)
    assert result["ok"] and execute(token,ident)==result,(name,result)
    return result


action(manager,"review_level1",p_action="RETURN",p_comment="補充規格")
action(applicant,"submit_request",p_resubmit_note="已核對規格")
action(manager,"review_level1",p_action="APPROVE")
action(drawing,"review_level2",p_action="APPROVE")
action(staff,"claim_issue")
args=dict(p_id=case,p_expected_version=version(staff))
keys=[prepare(staff,"record_issue",args) for _ in range(2)]
outcomes=race([(staff,k) for k in keys])
assert sorted(r["ok"] for r in outcomes)==[False,True]
assert outcomes==[execute(staff,k) for k in keys]
action(applicant,"case_exception",p_withdraw=False,p_reason="測試異常")
action(applicant,"case_exception",p_withdraw=True,p_reason="測試撤回")
args=dict(p_id=case,p_expected_version=version(applicant))
receipt=prepare(applicant,"confirm_receipt",args)
force=prepare(admin,"admin_force_close",{**args,"p_category":"其他","p_reason":"並發測試"})
outcomes=race([(applicant,receipt),(admin,force)])
assert sorted(r["ok"] for r in outcomes)==[False,True]
def matching(token, table, fields):
    req=Request(BASE+"/rest/v1/"+table+"?select="+fields+"&request_id=eq."+case,
                headers={"Authorization":"Bearer "+token})
    with build_opener(ProxyHandler({})).open(req) as response:
        return json.load(response)

assert matching(applicant,"line_mock_events","event")==[{"event":"initial"}]
assert matching(staff,"line_mock_events","event")==[{"event":"issue"}]
assert len(matching(admin,"review_records","id"))==3
assert len(matching(admin,"issue_claims","id"))==1
assert len(matching(admin,"issue_records","id"))==1
assert len(matching(admin,"case_exceptions","request_id"))==1
assert len(matching(admin,"exception_notices","id"))==1
print(case, original["number"], "PASS")
