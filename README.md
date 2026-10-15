# SE Industry Demos - Octopus Deploy demo space as code

One space, five industry project groups, plus Platform Engineering and Kubernetes/GitOps (Argo CD).
It's all simulated: steps run as scripts on Octopus Cloud dynamic workers, and they target Cloud Region
targets, so every project deploys with no real infrastructure. Phase 2 swaps in real targets and the
same processes keep working.

```
00-space/   creates the space (the provider has to be scoped to a space for stage 10)
10-demo/    everything else: environments, lifecycles, tags, feeds, workers, targets,
            tenants, library sets, step templates, teams, projects, runbooks, triggers, freezes
  scripts/  simulation scripts (bash / PowerShell) used by the steps
gitops/     Argo CD Applications (annotated) + kustomize overlays + manifest template for phase 2
deploy.sh   builds or rebuilds everything (+ uploads logos)   destroy.sh  tears it all down
seed-history.py  creates releases / deployments / failures / runbook runs
upload-logos.py  uploads logos/*.png as project logos
```

## Build it

Requirements: Terraform >= 1.5, an Octopus Cloud API key with admin rights.

```bash
export OCTOPUS_URL=https://<instance>.octopus.app
export OCTOPUS_API_KEY=API-xxxx
./deploy.sh
```

To reset the space after a demo, run `./deploy.sh` again. It puts back anything that drifted. To start
from a clean slate, run `./destroy.sh && ./deploy.sh`.

### After the first apply (5 minutes, one time)

1. **Publish runbooks.** Each runbook needs one publish before triggers can use it and before Runbook
   consumers can see it.
2. **Create a first release** in each project. Development auto-deploys, which gives the dashboards
   some history.
3. Optional: set `enable_scheduled_triggers = true` and re-apply. This turns on the nightly backup and
   the nightly Dev to Test promotion.
4. Optional: add your demo users to the teams (`FinTrust - Release Managers`, etc.) so the RBAC and
   approval demos show real separation of duties.

### If an apply fails

This code was checked against the provider v1.20 docs: attribute names, required fields, and block vs
attribute syntax. It has not yet been run against a live instance. These are the parts most likely to
need a tweak:

| Area | Fix |
|---|---|
| `Platform - FinTrust Release Train` (`Octopus.DeployRelease` step) | set `enable_release_train = false`, then add the 3 *Deploy a Release* steps in the UI |
| Docker Hub needs a login to list tags | podinfo now comes from GitHub Container Registry; set `docker_hub_username` / `docker_hub_token` only if you add Docker Hub images |
| Tenant variable resources (V2 API) | re-run apply; they depend on the tenant to project links |

## What is where

| Project group | Projects | Headline features |
|---|---|---|
| Financial Services - FinTrust Bank | Payments API, Core Banking Database, Fraud Scoring Model | Regulated lifecycle with DR phase, change ticket + manual intervention by responsible team, env-scoped RBAC, rolling deploy with child steps, Hotfix channel, versioning template, sensitive + prompted variables, SQL preview artifacts + DBA review, backup / point-in-time restore runbooks, year-end freeze |
| Healthcare - MediCore Health | Patient Portal, HL7 Integration Engine | 5 hospital tenants, Region / Tier / Ring tags, tenant project + common variables (incl. sensitive), shared vs dedicated tenanted targets, Preview Ring channel, tenant-tag-scoped feature flags, tenanted runbooks, tenant-specific freeze, HIPAA audit artifact |
| Manufacturing - Forge Industries | MES Plant Services, Edge Firmware Rollout, SCADA Gateway (Windows) | 8 plant edge targets, role-scoped variables, rolling window, canary then fleet with go/no-go, target trigger for new gateways, skip unavailable machines, Windows workers + PowerShell, diagnostics runbook |
| Retail - Cartwheel Commerce | Storefront Web, Inventory Service, Order Processing | Docker image references, external feed trigger, pre-release channel rule, blue/green with output variables, failure-condition rollback step, peak-season annual freeze, parallel steps, scheduled promotion, fast-track lifecycle, **live Config as Code conversion** |
| Public Sector - CivicOne | Citizen Services Portal, Records Archive (Air-gapped) | Required (non-skippable) steps, SBOM + scan artifacts, dual approval by 2 teams, compliance evidence-pack runbook, signed offline bundle |
| Platform Engineering | Landing Zone Provisioning, FinTrust Release Train | Provisioning / teardown runbooks, Select prompted variable, worker pool variable, conditional variable expressions, Deploy a Release orchestration |
| Kubernetes & GitOps - Argo CD | Podinfo (Image Tags), Podinfo (Manifests), Podinfo Helm (K8s Agent) | Octopus promotion + approvals over Argo CD, env-scoped manifest variables, slugs that match the Argo annotations |

Everything in the space: 5 environments (+ Ephemeral parent), 5 lifecycles, 7 tag sets, 2 dynamic worker
pools, 3 feeds, 4 library variable sets, 1 script module, 2 custom step templates, 5 teams, ~40 Cloud
Region targets, 5 tenants, 3 deployment freezes.

**Demo switches:** every project includes `Demo Controls`. Tick *Fail the smoke test / security scan /
canary* when you deploy and you get a failure on demand. Use it for guided failure, AI failure analysis,
Recovery Agent and rollback stories.

## Phase 2 - real infrastructure

### Argo CD (project group `Kubernetes & GitOps - Argo CD`)

1. Run a cluster with Argo CD (kind / k3d is fine).
2. The Argo CD Applications already point at `https://github.com/kamloicc/octo-demo` (`gitops/` folder). If the repo is private, add it to Argo CD with a token.
3. In Octopus, go to **Infrastructure > Argo CD Instances > Add**, paste an Argo CD token, then run the
   generated Helm command to install the gateway.
4. Add a **Git credential** with a repository restriction for that repo. The Argo steps pick the
   credential by URL.
5. Run `kubectl apply -f gitops/argocd-apps/`. The annotations already match the Octopus slugs
   (`argo-podinfo-image-tags` + `development|test|staging|production`, space `se-industry-demos`).
6. In **Argo CD - Podinfo (Image Tags)**, disable the "- simulated" step and add
   **Update Argo CD Application Image Tags** with container `stefanprodan/podinfo` from the GitHub Container Registry feed.
   Set verification to *Argo CD Application is healthy*, and set *Pull request* for Production if you
   want a PR-based promotion.
7. In **Argo CD - Podinfo (Manifests)**, add **Update Argo CD Application Manifests** pointing at
   `gitops/templates/`, then add annotations for that project too. You can generate them under
   *Argo CD instance > Generate Scoping Annotations*.

### Kubernetes agent / Tentacles / cloud

- Install the Kubernetes agent with target tag `k8s-podinfo`, then use *Deploy a Helm Chart* with the
  `Helm - podinfo` feed.
- To swap a Cloud Region target for a real Tentacle / SSH / Azure / AWS target, keep the same **target
  tag** (role). The processes don't change.

### Live demos to do in the UI (not in Terraform, on purpose)

- **Config as Code:** convert *Cartwheel - Inventory Service* to version control live. After that,
  branch it, edit the OCL, and create a release from the branch.
- **Ephemeral environments:** once Inventory Service is CaC, add an *Ephemeral environment* channel
  that uses the `Ephemeral` parent environment and the *Platform - Landing Zone Provisioning* runbooks.
- **ITSM:** with ServiceNow / Jira Service Management configured, turn on change controls on the
  Production environment and the FinTrust projects. The simulated change step shows the flow until then.
- **Insights, Audit log, AI Assistant, MCP server:** these work across the space once you have some
  deployment history.
