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
| Docker Hub / GHCR need a login to list tags | set `TF_VAR_ghcr_username` + `TF_VAR_ghcr_token` (GitHub classic PAT, `read:packages`) before `./deploy.sh` |
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

## Real infrastructure (Kubernetes agent + Argo CD)

### Kubernetes agent - fully managed by Terraform

`Kubernetes - Podinfo Helm (K8s Agent)` deploys the podinfo Helm chart through the agent with target
tag `k8s-podinfo` (change with `-var k8s_target_tag=...`). Each environment gets its own namespace
`podinfo-helm-<env>`, replica count and UI colour. Environments without an agent are skipped.
Tick *Fail the deployment step?* to push a non-existent image tag: the rollout fails for real
(ImagePullBackOff), which shows the object status check, failure analysis and Live Status.

### Argo CD - one-time UI step per project

The native Argo CD step types can't be created through the Terraform provider yet. Terraform manages the
projects, variables and approvals, and you add the native step once in the UI. Terraform keeps steps
added in the UI and appends them after its own steps.

1. Push `gitops/` to `https://github.com/kamloicc/octo-demo` (already done if you pushed the repo).
2. **Infrastructure > Git Credentials**: add a GitHub token with write access. Under repository
   restrictions, allow `https://github.com/kamloicc/octo-demo.git`.
3. `kubectl apply -f gitops/argocd-apps/` creates 4 Argo CD apps (`podinfo-<env>`) already annotated
   with `argo-podinfo-image-tags` + the environment slugs. Check that they appear under
   **Infrastructure > Argo CD Instances > Applications**.
4. **Argo CD - Podinfo (Image Tags) > Process > Add step > Update Argo CD Application Image Tags**:
   - Container image: feed **GitHub Container Registry**, package `stefanprodan/podinfo`,
     reference name `podinfo`
   - Commit method: direct commit for Dev/Test, *Pull request* for Production
   - Verification: *Argo CD Application is healthy*
5. **Argo CD - Podinfo (Manifests)**: add **Update Argo CD Application Manifests** with templates
   path `gitops/templates`. Generate annotations for this project from
   *Argo CD instance > Generate Scoping Annotations* and add a second set of apps if you want both demos live.
6. Run `terraform -chdir=10-demo apply` once afterwards. Terraform should report only the
   "appended unmanaged steps" warning.

### Live demos to do in the UI (not in Terraform, on purpose)

- **Config as Code:** convert *Cartwheel - Inventory Service* to version control live. After that,
  branch it, edit the OCL, and create a release from the branch.
- **Ephemeral environments:** once Inventory Service is CaC, add an *Ephemeral environment* channel
  that uses the `Ephemeral` parent environment and the *Platform - Landing Zone Provisioning* runbooks.
- **ITSM:** with ServiceNow / Jira Service Management configured, turn on change controls on the
  Production environment and the FinTrust projects. The simulated change step shows the flow until then.
- **Insights, Audit log, AI Assistant, MCP server:** these work across the space once you have some
  deployment history.
