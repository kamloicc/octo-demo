# =============================================================================
# FOUNDATION: environments, workers, feeds, tags, lifecycles, project groups
# =============================================================================

# --- Tag sets (environment / project / runbook / tenant scopes) --------------
resource "octopusdeploy_tag_set" "env_tier" {
  name        = "Environment Tier"
  description = "Classifies environments. Demo: environment tags + scoping."
  scopes      = ["Environment"]
  type        = "SingleSelect"
}
resource "octopusdeploy_tag" "env_nonprod" {
  name       = "Non-Production"
  color      = "#2E7D32"
  tag_set_id = octopusdeploy_tag_set.env_tier.id
}
resource "octopusdeploy_tag" "env_prod" {
  name       = "Production"
  color      = "#C62828"
  tag_set_id = octopusdeploy_tag_set.env_tier.id
}

resource "octopusdeploy_tag_set" "compliance" {
  name        = "Compliance"
  description = "Regulatory frameworks a project falls under. Demo: project tags, filtering, reporting."
  scopes      = ["Project"]
  type        = "MultiSelect"
}
resource "octopusdeploy_tag" "compliance" {
  for_each   = { pci = ["PCI-DSS", "#6A1B9A"], sox = ["SOX", "#4527A0"], hipaa = ["HIPAA", "#00838F"], gdpr = ["GDPR", "#1565C0"], iso = ["ISO 27001", "#37474F"], fedramp = ["FedRAMP", "#AD1457"], iec = ["IEC 62443", "#EF6C00"] }
  name       = each.value[0]
  color      = each.value[1]
  tag_set_id = octopusdeploy_tag_set.compliance.id
}

resource "octopusdeploy_tag_set" "runbook_type" {
  name   = "Runbook Type"
  scopes = ["Runbook"]
  type   = "SingleSelect"
}
resource "octopusdeploy_tag" "runbook_type" {
  for_each   = { maint = ["Routine Maintenance", "#2E7D32"], incident = ["Incident Response", "#C62828"], prov = ["Provisioning", "#1565C0"], dr = ["Disaster Recovery", "#6A1B9A"] }
  name       = each.value[0]
  color      = each.value[1]
  tag_set_id = octopusdeploy_tag_set.runbook_type.id
}

# Tenant tag sets
resource "octopusdeploy_tag_set" "region" {
  name   = "Region"
  scopes = ["Tenant"]
  type   = "SingleSelect"
}
resource "octopusdeploy_tag" "region" {
  for_each   = { na = ["North America", "#1565C0"], emea = ["EMEA", "#2E7D32"], apac = ["APAC", "#EF6C00"] }
  name       = each.value[0]
  color      = each.value[1]
  tag_set_id = octopusdeploy_tag_set.region.id
}

resource "octopusdeploy_tag_set" "tier" {
  name   = "Customer Tier"
  scopes = ["Tenant"]
  type   = "MultiSelect" # shared targets carry several tiers
}
resource "octopusdeploy_tag" "tier" {
  for_each   = { std = ["Standard", "#78909C"], prem = ["Premium", "#1565C0"], ent = ["Enterprise", "#6A1B9A"] }
  name       = each.value[0]
  color      = each.value[1]
  tag_set_id = octopusdeploy_tag_set.tier.id
}

resource "octopusdeploy_tag_set" "ring" {
  name        = "Release Ring"
  description = "Progressive delivery rings for tenanted rollouts."
  scopes      = ["Tenant"]
  type        = "SingleSelect"
}
resource "octopusdeploy_tag" "ring" {
  for_each   = { canary = ["Canary", "#C62828"], early = ["Early Adopter", "#EF6C00"], ga = ["General Availability", "#2E7D32"] }
  name       = each.value[0]
  color      = each.value[1]
  tag_set_id = octopusdeploy_tag_set.ring.id
}

# --- Environments ------------------------------------------------------------
# Explicit slugs: Argo CD scoping annotations reference environment slugs.
# sort_order is not set: provider v1.20 ignores it on create. Octopus appends
# environments in creation order, so the depends_on chain fixes the order.
resource "octopusdeploy_environment" "development" {
  name                         = "Development"
  slug                         = "development"
  allow_dynamic_infrastructure = true
  environment_tags             = [octopusdeploy_tag.env_nonprod.canonical_tag_name]
}
resource "octopusdeploy_environment" "test" {
  depends_on = [octopusdeploy_environment.development] # creation order = display order
  name                         = "Test"
  slug                         = "test"
  allow_dynamic_infrastructure = true
  environment_tags             = [octopusdeploy_tag.env_nonprod.canonical_tag_name]
}
resource "octopusdeploy_environment" "staging" {
  depends_on = [octopusdeploy_environment.test] # creation order = display order
  name                         = "Staging"
  slug                         = "staging"
  allow_dynamic_infrastructure = true
  environment_tags             = [octopusdeploy_tag.env_nonprod.canonical_tag_name]
}
resource "octopusdeploy_environment" "production" {
  depends_on = [octopusdeploy_environment.staging] # creation order = display order
  name              = "Production"
  slug              = "production"
  use_guided_failure = true # Demo: guided failure (retry / ignore / abort)
  environment_tags  = [octopusdeploy_tag.env_prod.canonical_tag_name]
}
resource "octopusdeploy_environment" "dr" {
  depends_on = [octopusdeploy_environment.production] # creation order = display order
  name               = "Disaster Recovery"
  slug               = "disaster-recovery"
  description        = "Optional phase in regulated lifecycles. Demo: optional phases and DR runbooks."
  use_guided_failure = true
  environment_tags   = [octopusdeploy_tag.env_prod.canonical_tag_name]
}

# Parent environment for Ephemeral Environments (feature-branch / PR envs)
resource "octopusdeploy_parent_environment" "ephemeral" {
  space_id    = var.space_id
  name        = "Ephemeral"
  description = "Parent for short-lived PR / feature environments. Auto-deprovisioned after 1 day."
  automatic_deprovisioning_rule = {
    days  = 1
    hours = 0
  }
}

# --- Workers (Octopus Cloud dynamic workers) ----------------------------------
resource "octopusdeploy_dynamic_worker_pool" "ubuntu" {
  name        = "Demo Linux Workers"
  description = "Octopus Cloud dynamic Ubuntu workers. All simulated steps run here."
  worker_type = "UbuntuDefault"
  is_default  = true
}
resource "octopusdeploy_dynamic_worker_pool" "windows" {
  name        = "Demo Windows Workers"
  description = "Octopus Cloud dynamic Windows workers (PowerShell demos)."
  worker_type = "WindowsDefault"
}

# --- Feeds -------------------------------------------------------------------
resource "octopusdeploy_docker_container_registry" "docker_hub" {
  name        = "Docker Hub"
  feed_uri    = "https://index.docker.io"
  api_version = "v2"
  username    = var.docker_hub_username != "" ? var.docker_hub_username : null
  password    = var.docker_hub_token != "" ? var.docker_hub_token : null
}
resource "octopusdeploy_docker_container_registry" "ghcr" {
  name        = "GitHub Container Registry"
  feed_uri    = "https://ghcr.io"
  api_version = "v2"
}
resource "octopusdeploy_helm_feed" "podinfo" {
  name     = "Helm - podinfo"
  feed_uri = "https://stefanprodan.github.io/podinfo"
}

# --- Lifecycles --------------------------------------------------------------
resource "octopusdeploy_lifecycle" "standard" {
  name        = "Standard (Dev > Test > Staging > Prod)"
  description = "Auto-deploys to Development. Each phase must succeed before promotion."
  release_retention_with_strategy {
    strategy         = "Count"
    quantity_to_keep = 30
    unit             = "Days"
  }
  tentacle_retention_with_strategy {
    strategy         = "Count"
    quantity_to_keep = 3
    unit             = "Items"
  }
  phase {
    name                         = "Development"
    automatic_deployment_targets = [local.env.dev]
  }
  phase {
    name                        = "Test"
    optional_deployment_targets = [local.env.test]
  }
  phase {
    name                        = "Staging"
    optional_deployment_targets = [local.env.staging]
  }
  phase {
    name                        = "Production"
    optional_deployment_targets = [local.env.prod]
    is_priority_phase           = true
    release_retention_with_strategy {
      strategy = "Forever"
    }
  }
}

resource "octopusdeploy_lifecycle" "regulated" {
  name        = "Regulated (Dev > Test > Staging > Prod > DR)"
  description = "For SOX / PCI / HIPAA workloads. Prod releases are kept forever for audit. DR is optional."
  release_retention_with_strategy {
    strategy = "Forever"
  }
  phase {
    name                         = "Development"
    automatic_deployment_targets = [local.env.dev]
  }
  phase {
    name                        = "Test"
    optional_deployment_targets = [local.env.test]
  }
  phase {
    name                        = "Staging"
    optional_deployment_targets = [local.env.staging]
  }
  phase {
    name                        = "Production"
    optional_deployment_targets = [local.env.prod]
    is_priority_phase           = true
  }
  phase {
    name                        = "Disaster Recovery"
    optional_deployment_targets = [local.env.dr]
    is_optional_phase           = true
  }
}

resource "octopusdeploy_lifecycle" "hotfix" {
  name        = "Hotfix (Staging > Prod)"
  description = "Used by Hotfix channels to skip lower environments."
  phase {
    name                        = "Staging"
    optional_deployment_targets = [local.env.staging]
  }
  phase {
    name                        = "Production"
    optional_deployment_targets = [local.env.prod]
  }
}

resource "octopusdeploy_lifecycle" "feature" {
  name        = "Feature Branch (Dev only)"
  description = "Pre-release packages only reach Development."
  release_retention_with_strategy {
    strategy         = "Count"
    quantity_to_keep = 5
    unit             = "Items"
  }
  phase {
    name                         = "Development"
    automatic_deployment_targets = [local.env.dev]
  }
}

resource "octopusdeploy_lifecycle" "nonprod_fast" {
  name        = "Fast Track (Dev > Test, minimum 1)"
  description = "Demo: 'minimum environments before promotion'."
  phase {
    name                                  = "Non-Production"
    optional_deployment_targets           = [local.env.dev, local.env.test]
    minimum_environments_before_promotion = 1
  }
  phase {
    name                        = "Production"
    optional_deployment_targets = [local.env.prod]
  }
}

# --- Project groups ----------------------------------------------------------
resource "octopusdeploy_project_group" "finance" {
  name        = "Financial Services - FinTrust Bank"
  description = "Approvals, ITSM change control, deployment freezes, DB migrations, rolling deploys, audit."
}
resource "octopusdeploy_project_group" "healthcare" {
  name        = "Healthcare - MediCore Health"
  description = "Multi-tenancy (hospitals), tenant variables, release rings, HIPAA runbooks."
}
resource "octopusdeploy_project_group" "manufacturing" {
  name        = "Manufacturing - Forge Industries"
  description = "Edge / plant-floor deployments, canary + rolling, target triggers, Windows workloads."
}
resource "octopusdeploy_project_group" "retail" {
  name        = "Retail - Cartwheel Commerce"
  description = "Blue/green, container images, external feed triggers, peak-season freeze, Config as Code."
}
resource "octopusdeploy_project_group" "public_sector" {
  name        = "Public Sector - CivicOne"
  description = "Separation of duties, multi-team approvals, security evidence, air-gapped delivery."
}
resource "octopusdeploy_project_group" "platform" {
  name        = "Platform Engineering"
  description = "Infrastructure runbooks, release orchestration, shared tooling."
}
resource "octopusdeploy_project_group" "gitops" {
  name        = "Kubernetes & GitOps - Argo CD"
  description = "Octopus + Argo CD: environment promotion, approvals and verification on top of GitOps."
}
