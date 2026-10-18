#!/usr/bin/env python3
"""
Seed realistic release / deployment / runbook history across the demo space.

For every project it creates N releases and promotes them through the lifecycle
(per tenant where the project is tenanted). A share of deployments fail on
purpose via the Demo.FailDeployment prompted variable. Manual interventions are
approved automatically, guided-failure prompts are answered "Fail", and every
runbook is published and run once or twice.

Usage:
  export OCTOPUS_URL=https://<instance>.octopus.app OCTOPUS_API_KEY=API-xxx
  python3 seed-history.py                      # 3 releases per project, 20% failures
  python3 seed-history.py --releases 2 --fail-rate 0.3 --project Cartwheel
  python3 seed-history.py --releases 1 --last-reaches 4 --no-runbooks   # one new wave, all the way to Prod
  python3 seed-history.py --runbooks-only

Only the Python standard library is used.
"""
import argparse, json, os, random, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone

URL = os.environ.get("OCTOPUS_URL", "").rstrip("/")
KEY = os.environ.get("OCTOPUS_API_KEY", "")
SPACE_NAME = os.environ.get("OCTOPUS_SPACE", "SE Industry Demos")

WORK_ITEMS = ["PAY-1042 Add 3DS2 challenge flow", "PAY-1077 Retry idempotency keys", "MED-311 Appointment reminders",
              "MED-329 FHIR R4 Patient search", "FRG-88 OPC-UA reconnect backoff", "CART-512 One-click checkout",
              "CART-530 Inventory cache TTL", "CIV-207 Accessibility fixes (WCAG 2.2)", "PLAT-19 Upgrade base image",
              "SEC-401 Patch openssl CVE"]


# ---------------------------------------------------------------- HTTP helpers
def api(method, path, body=None, ok404=False):
    url = path if path.startswith("http") else f"{URL}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"X-Octopus-ApiKey": KEY, "Content-Type": "application/json"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            msg = e.read().decode(errors="replace")
            if e.code == 404 and ok404:
                return None
            if e.code in (429, 502, 503, 504) and attempt < 3:
                time.sleep(2 * (attempt + 1)); continue
            raise RuntimeError(f"{method} {path} -> {e.code}: {msg[:400]}")
        except urllib.error.URLError:
            if attempt < 3:
                time.sleep(2); continue
            raise


def get_all(path):
    sep = "&" if "?" in path else "?"
    items, skip = [], 0
    while True:
        page = api("GET", f"{path}{sep}skip={skip}&take=100")
        batch = page.get("Items", [])
        items += batch
        if len(batch) < 100:
            return items
        skip += 100


def log(msg):
    print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


# ---------------------------------------------------------------- model
class Ctx:
    def __init__(self, space_id):
        self.s = space_id
        self.envs = {e["Id"]: e for e in get_all(f"/api/{space_id}/environments")}
        self.env_order = [e["Id"] for e in sorted(self.envs.values(), key=lambda e: e.get("SortOrder", 0))]
        self.tenants = get_all(f"/api/{space_id}/tenants")
        self.lifecycles = {l["Id"]: l for l in get_all(f"/api/{space_id}/lifecycles")}
        self.pending = {}   # task id -> description

    def p(self, path):
        return f"/api/{self.s}{path}"


def lifecycle_envs(ctx, lifecycle_id):
    """Ordered list of environment IDs a lifecycle can reach."""
    lc = ctx.lifecycles.get(lifecycle_id)
    if not lc or not lc.get("Phases"):
        return list(ctx.env_order)
    out = []
    for ph in lc["Phases"]:
        for e in ph.get("AutomaticDeploymentTargets", []) + ph.get("OptionalDeploymentTargets", []):
            if e not in out:
                out.append(e)
    return out


def latest_version(ctx, feed_id, package_id, pre=False):
    q = urllib.parse.urlencode({"packageId": package_id, "take": 1, "includePreRelease": str(pre).lower()})
    try:
        res = api("GET", ctx.p(f"/feeds/{feed_id}/packages/versions?{q}"))
        items = res.get("Items", [])
        return items[0]["Version"] if items else None
    except RuntimeError as e:
        log(f"   ! cannot list versions for {package_id}: {e}")
        return None


def create_release(ctx, project, channel, n):
    tmpl = api("GET", ctx.p(f"/deploymentprocesses/{project['DeploymentProcessId']}/template?channel={channel['Id']}"))
    selected = []
    for pkg in tmpl.get("Packages", []):
        ver = latest_version(ctx, pkg["FeedId"], pkg["PackageId"])
        if not ver and "podinfo" in pkg["PackageId"]:
            ver = random.choice(["6.7.0", "6.7.1", "6.8.0"])
            log(f"   ! using fallback version {ver} for {pkg['PackageId']}")
        if not ver:
            log(f"   ! no version for package {pkg['PackageId']} - skipping project")
            return None
        selected.append({"ActionName": pkg["ActionName"], "PackageReferenceName": pkg.get("PackageReferenceName", ""), "Version": ver})
    items = random.sample(WORK_ITEMS, 2)
    notes = f"Seeded release #{n}\n\n" + "\n".join(f"- {w}" for w in items)
    version = tmpl.get("NextVersionIncrement") or f"1.{n}.{int(time.time()) % 100000}"
    body = {"ProjectId": project["Id"], "ChannelId": channel["Id"], "Version": version,
            "ReleaseNotes": notes, "SelectedPackages": selected}
    rel = api("POST", ctx.p("/releases"), body)
    log(f"   + release {rel['Version']}")
    return rel


def deployment_preview(ctx, release_id, env_id, tenant_id):
    path = f"/releases/{release_id}/deployments/preview/{env_id}" + (f"/{tenant_id}" if tenant_id else "")
    try:
        prev = api("GET", ctx.p(path), ok404=True)
        if prev and "Form" in prev:
            return prev
    except RuntimeError:
        pass
    try:  # newer API shape
        res = api("POST", ctx.p(f"/releases/{release_id}/deployments/previews"),
                  {"DeploymentPreviews": [{"EnvironmentId": env_id, "TenantId": tenant_id}], "IncludeDisabledSteps": False})
        res = res[0] if isinstance(res, list) and res else res
        return res if res and "Form" in res else None
    except RuntimeError:
        return None


def form_values(ctx, release_id, env_id, tenant_id, fail):
    prev = deployment_preview(ctx, release_id, env_id, tenant_id)
    if not prev:
        if fail:
            log("   ! no deployment preview available - cannot inject failure")
        return {}
    wanted = {"Demo.FailDeployment": "True" if fail else "False",
              "Change.Ticket": f"CHG{random.randint(100000, 999999)}"}
    vals = {}
    for el in prev["Form"].get("Elements", []):
        name = (el.get("Control") or {}).get("Name")
        if name in wanted:
            vals[el["Name"]] = wanted[name]
    return vals


def deploy(ctx, project, release, env_id, tenant=None, fail=False):
    env_name = ctx.envs[env_id]["Name"]
    body = {"ReleaseId": release["Id"], "EnvironmentId": env_id,
            "Comments": "Seeded by seed-history.py" + (" (expected failure)" if fail else ""),
            "FormValues": form_values(ctx, release["Id"], env_id, tenant and tenant["Id"], fail)}
    if tenant:
        body["TenantId"] = tenant["Id"]
    try:
        d = api("POST", ctx.p("/deployments"), body)
    except RuntimeError as e:
        log(f"   ! deploy {project['Name']} {release['Version']} -> {env_name}{' / ' + tenant['Name'] if tenant else ''}: {e}")
        return None
    ctx.pending[d["TaskId"]] = f"{project['Name']} {release['Version']} -> {env_name}" + (f" / {tenant['Name']}" if tenant else "")
    return d["TaskId"]


# ---------------------------------------------------------------- interruptions + waiting
def pump_interruptions(ctx):
    try:
        items = api("GET", ctx.p("/interruptions?pendingOnly=true&take=100")).get("Items", [])
    except RuntimeError as e:
        log(f"   ! interruptions: {e}"); return
    for it in items:
        if it.get("TaskId") not in ctx.pending:
            continue  # only answer prompts on tasks this script started
        names = [e.get("Name") for e in (it.get("Form") or {}).get("Elements", [])]
        if "Guidance" not in names and "Result" not in names:
            continue  # system wait (e.g. "Wait for Argo CD Applications") - resolves by itself
        try:
            if not it.get("HasResponsibility"):
                if not it.get("CanTakeResponsibility", True):
                    log(f"   ! cannot take responsibility for '{it.get('Title')}' - cancelling task {it['TaskId']}")
                    api("POST", f"/api/tasks/{it['TaskId']}/cancel")
                    continue
                api("PUT", ctx.p(f"/interruptions/{it['Id']}/responsible"))
            vals = {"Notes": "Auto-answered by seed-history.py"}
            if "Guidance" in names:
                vals["Guidance"] = "Fail"
                what = "guided failure -> Fail"
            else:
                vals["Result"] = "Proceed"
                what = "manual intervention -> Proceed"
            api("POST", ctx.p(f"/interruptions/{it['Id']}/submit"), vals)
            log(f"   ~ {ctx.pending[it['TaskId']]}: {what}")
        except RuntimeError as e:
            log(f"   ! interruption {it['Id']}: {e}")


def wait_all(ctx, timeout=3600):
    """Wait for every pending task; returns {task_id: state}."""
    results, start = {}, time.time()
    while ctx.pending and time.time() - start < timeout:
        pump_interruptions(ctx)
        for tid in list(ctx.pending):
            t = api("GET", f"/api/tasks/{tid}")
            if t.get("IsCompleted"):
                state = t.get("State")
                mark = {"Success": "OK  ", "Failed": "FAIL", "Canceled": "CANC"}.get(state, state)
                log(f"   {mark} {ctx.pending.pop(tid)}")
                results[tid] = state
        if ctx.pending:
            time.sleep(8)
    for tid in list(ctx.pending):
        log(f"   TIMEOUT {ctx.pending.pop(tid)}")
        results[tid] = "Timeout"
    return results


# ---------------------------------------------------------------- deployments
def plan_project(ctx, project, n_releases, fail_rate):
    """Returns a list of (release, [(env_id, tenant_or_None)...] per stage)."""
    log(f"   reading {project['Name']}...")
    proc = api("GET", ctx.p(f"/deploymentprocesses/{project['DeploymentProcessId']}"))
    if not proc.get("Steps"):
        log(f"-- {project['Name']}: no deployment steps, skipped")
        return None
    channels = get_all(ctx.p(f"/projects/{project['Id']}/channels"))
    channel = next((c for c in channels if c.get("IsDefault")), channels[0])
    envs = lifecycle_envs(ctx, channel.get("LifecycleId") or project["LifecycleId"])
    mode = project.get("TenantedDeploymentMode", "Untenanted")
    tenants = [t for t in ctx.tenants if project["Id"] in (t.get("ProjectEnvironments") or {})]
    return {"project": project, "channel": channel, "envs": envs, "mode": mode, "tenants": tenants}


def targets_for(plan, env_id):
    out = []
    if plan["mode"] != "Untenanted":
        out += [t for t in plan["tenants"] if env_id in t["ProjectEnvironments"].get(plan["project"]["Id"], [])]
    if plan["mode"] != "Tenanted" and not out:
        out.append(None)
    return out


def seed_deployments(ctx, projects, n_releases, fail_rate, last_depth=2):
    plans = [p for p in (plan_project(ctx, pr, n_releases, fail_rate) for pr in projects) if p]
    trains = [p for p in plans if "Release Train" in p["project"]["Name"]]
    plans = [p for p in plans if p not in trains]

    for r in range(1, n_releases + 1):
        # how far this release travels: older releases reach prod, the newest stops earlier
        log(f"=== Release round {r}/{n_releases}")
        rels = {}
        for pl in plans:
            log(f"-- {pl['project']['Name']}")
            try:
                rel = create_release(ctx, pl["project"], pl["channel"], r)
            except RuntimeError as e:
                log(f"   ! release failed: {e}"); rel = None
            if rel:
                rels[pl["project"]["Id"]] = (pl, rel, True)  # alive = no failure yet
        # let auto-deploy (Development phase) kick in, then adopt those tasks
        time.sleep(10)
        auto = {}
        for pid, (pl, rel, _) in rels.items():
            for d in get_all(ctx.p(f"/releases/{rel['Id']}/deployments")):
                ctx.pending[d["TaskId"]] = f"{pl['project']['Name']} {rel['Version']} -> {ctx.envs[d['EnvironmentId']]['Name']} (auto)"
                auto[d["TaskId"]] = pid

        depth = len(ctx.env_order) if r < n_releases else last_depth  # newest release stops early
        for stage in range(depth):
            wave = dict(auto) if stage == 0 else {}
            for pid, (pl, rel, alive) in rels.items():
                if not alive or stage >= len(pl["envs"]):
                    continue
                env_id = pl["envs"][stage]
                env_name = ctx.envs[env_id]["Name"]
                if env_name == "Disaster Recovery" and random.random() < 0.6:
                    continue  # optional phase, only sometimes
                existing = {(d["EnvironmentId"], d.get("TenantId")) for d in get_all(ctx.p(f"/releases/{rel['Id']}/deployments"))}
                for tenant in targets_for(pl, env_id):
                    if (env_id, tenant and tenant["Id"]) in existing:
                        continue
                    fail = random.random() < fail_rate
                    tid = deploy(ctx, pl["project"], rel, env_id, tenant, fail)
                    if tid:
                        wave[tid] = pid
                    else:
                        rels[pid] = (pl, rel, False)  # could not deploy: stop promoting this release
                        break
            if not wave and not ctx.pending:
                continue
            log(f"   ... waiting for {len(ctx.pending)} task(s) (stage {stage + 1})")
            res = wait_all(ctx)
            for tid, state in res.items():
                pid = wave.get(tid)
                if pid and state != "Success":
                    pl, rel, _ = rels[pid]
                    rels[pid] = (pl, rel, False)  # stop promoting a failed release

    for pl in trains:
        log(f"-- {pl['project']['Name']} (orchestration)")
        try:
            rel = create_release(ctx, pl["project"], pl["channel"], 1)
        except RuntimeError as e:
            log(f"   ! {e}"); continue
        time.sleep(10)
        for d in get_all(ctx.p(f"/releases/{rel['Id']}/deployments")):
            ctx.pending[d["TaskId"]] = f"{pl['project']['Name']} {rel['Version']} -> {ctx.envs[d['EnvironmentId']]['Name']} (auto)"
        wait_all(ctx)
        for env_id in pl["envs"][1:3]:
            deploy(ctx, pl["project"], rel, env_id)
            wait_all(ctx)


# ---------------------------------------------------------------- runbooks
def seed_runbooks(ctx, projects):
    log("=== Runbooks: publish + run")
    for pr in projects:
        for rb in get_all(ctx.p(f"/projects/{pr['Id']}/runbooks")):
            try:
                snap = api("POST", ctx.p("/runbookSnapshots?publish=true"),
                           {"ProjectId": pr["Id"], "RunbookId": rb["Id"], "Name": f"Snapshot {datetime.now():%Y%m%d-%H%M%S}"})
                log(f"-- published {pr['Name']} / {rb['Name']}")
            except RuntimeError as e:
                log(f"   ! publish {rb['Name']}: {e}"); continue
            scope = rb.get("EnvironmentScope", "All")
            envs = rb.get("Environments") if scope == "Specified" else ctx.env_order
            envs = [e for e in envs if e in ctx.envs]
            prod = [e for e in envs if ctx.envs[e]["Name"] == "Production"]
            picks = list(dict.fromkeys([envs[0]] + (prod or envs[-1:])))
            tenanted = rb.get("MultiTenancyMode", "Untenanted") == "Tenanted"
            tenants = [t for t in ctx.tenants if pr["Id"] in (t.get("ProjectEnvironments") or {})]
            for env_id in picks:
                run_tenants = [t for t in tenants if env_id in t["ProjectEnvironments"][pr["Id"]]][:2] if tenanted else [None]
                for t in run_tenants:
                    body = {"RunbookId": rb["Id"], "RunbookSnapshotId": snap["Id"], "EnvironmentId": env_id,
                            "FormValues": runbook_form(ctx, rb["Id"], env_id, t and t["Id"])}
                    if t:
                        body["TenantId"] = t["Id"]
                    try:
                        run = api("POST", ctx.p("/runbookRuns"), body)
                        ctx.pending[run["TaskId"]] = f"runbook {rb['Name']} -> {ctx.envs[env_id]['Name']}" + (f" / {t['Name']}" if t else "")
                    except RuntimeError as e:
                        log(f"   ! run {rb['Name']} in {ctx.envs[env_id]['Name']}: {e}")
    wait_all(ctx)


def runbook_form(ctx, runbook_id, env_id, tenant_id):
    path = f"/runbooks/{runbook_id}/runbookRuns/preview/{env_id}" + (f"/{tenant_id}" if tenant_id else "")
    try:
        prev = api("GET", ctx.p(path), ok404=True)
    except RuntimeError:
        return {}
    if not prev or "Form" not in prev:
        return {}
    wanted = {"Restore.PointInTime": (datetime.now(timezone.utc) - timedelta(hours=6)).strftime("%Y-%m-%dT%H:00:00Z"),
              "Runbook.Reason": f"INC{random.randint(10000, 99999)} - seeded run",
              "Infra.Size": random.choice(["small", "medium"])}
    return {el["Name"]: wanted[(el.get("Control") or {}).get("Name")]
            for el in prev["Form"].get("Elements", []) if (el.get("Control") or {}).get("Name") in wanted}


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--releases", type=int, default=3, help="releases per project (default 3)")
    ap.add_argument("--fail-rate", type=float, default=0.2, help="share of deployments that fail (default 0.2)")
    ap.add_argument("--project", default="", help="only projects whose name contains this text")
    ap.add_argument("--last-reaches", type=int, default=2,
                    help="how many environments the newest release reaches (2 = Dev+Test, 4 = up to Production)")
    ap.add_argument("--runbooks-only", action="store_true")
    ap.add_argument("--no-runbooks", action="store_true")
    ap.add_argument("--seed", type=int, default=None, help="random seed for repeatable runs")
    a = ap.parse_args()
    if not URL or not KEY:
        sys.exit("Set OCTOPUS_URL and OCTOPUS_API_KEY")
    random.seed(a.seed)

    space = next((s for s in get_all("/api/spaces") if s["Name"] == SPACE_NAME), None)
    if not space:
        sys.exit(f"Space '{SPACE_NAME}' not found (set OCTOPUS_SPACE)")
    ctx = Ctx(space["Id"])
    projects = [p for p in get_all(ctx.p("/projects")) if a.project.lower() in p["Name"].lower() and not p.get("IsDisabled")]
    projects = [p for p in projects if not p.get("IsVersionControlled")]  # CaC projects need a git ref; skip
    log(f"Space {space['Id']}: {len(projects)} project(s), {len(ctx.tenants)} tenant(s)")

    if not a.runbooks_only:
        seed_deployments(ctx, projects, a.releases, a.fail_rate, a.last_reaches)
    if not a.no_runbooks:
        seed_runbooks(ctx, projects)
    log(f"Done. Dashboard: {URL}/app#/{ctx.s}/projects")


if __name__ == "__main__":
    main()
