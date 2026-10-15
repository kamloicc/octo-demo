# =============================================================================
# SIMULATED INFRASTRUCTURE
# Cloud Region targets need no real machines: steps run on dynamic workers
# "on behalf of" each target. This still demonstrates target tags, rolling
# deployments, per-target variables, tenanted infrastructure and target triggers.
# Swap for Tentacles / K8s agents later without changing the processes.
# =============================================================================

locals {
  untenanted_targets = merge(
    # Financial Services
    { for e in ["dev", "test", "staging"] : "fintrust-pay-${e}-01" => { env = e, roles = ["fintrust-payments-api"] } },
    { for i in ["01", "02", "03"] : "fintrust-pay-prod-${i}" => { env = "prod", roles = ["fintrust-payments-api"] } },
    { "fintrust-pay-dr-01" = { env = "dr", roles = ["fintrust-payments-api"] } },
    { for e in ["dev", "test", "staging", "prod", "dr"] : "fintrust-coredb-${e}" => { env = e, roles = ["fintrust-core-db"] } },

    # Manufacturing: plant floor edge gateways (prod) + lab gateways (non-prod)
    { for e in ["dev", "test", "staging"] : "forge-lab-${e}" => { env = e, roles = ["forge-mes-edge", "forge-canary"] } },
    { for p in setproduct(["detroit", "monterrey", "stuttgart", "pune"], ["line1", "line2"]) :
      "forge-${p[0]}-${p[1]}" => {
        env   = "prod"
        roles = concat(["forge-mes-edge", "plant-${p[0]}"], p[0] == "detroit" && p[1] == "line1" ? ["forge-canary"] : [])
      }
    },

    # Retail
    { for e in ["dev", "test", "staging"] : "cartwheel-web-${e}" => { env = e, roles = ["cartwheel-web"] } },
    { for i in ["01", "02"] : "cartwheel-web-prod-${i}" => { env = "prod", roles = ["cartwheel-web"] } },

    # Public Sector
    { for e in ["dev", "test", "staging", "prod"] : "civicone-portal-${e}" => { env = e, roles = ["civicone-portal"] } },
  )

  # Healthcare: shared regional clusters used by tenants matching the Region tag
  health_regions = {
    na   = octopusdeploy_tag.region["na"].canonical_tag_name
    emea = octopusdeploy_tag.region["emea"].canonical_tag_name
    apac = octopusdeploy_tag.region["apac"].canonical_tag_name
  }
  health_targets = {
    for p in setproduct(keys(local.health_regions), ["test", "staging", "prod"]) :
    "medicore-${p[0]}-${p[1]}" => { region = p[0], env = p[1] }
  }
}

resource "octopusdeploy_cloud_region_deployment_target" "untenanted" {
  for_each               = local.untenanted_targets
  name                   = each.key
  environments           = [local.env[each.value.env]]
  roles                  = each.value.roles
  default_worker_pool_id = local.wp_linux
}

resource "octopusdeploy_cloud_region_deployment_target" "health_shared" {
  for_each                          = local.health_targets
  name                              = each.key
  environments                      = [local.env[each.value.env]]
  roles                             = ["medicore-portal", "medicore-hl7"]
  default_worker_pool_id            = local.wp_linux
  tenanted_deployment_participation = "Tenanted"
  # Tags in the same set are OR'd, across sets AND'd:
  # Region = X AND Tier in (...). Enterprise tenants get dedicated prod infra.
  tenant_tags = concat(
    [local.health_regions[each.value.region]],
    [octopusdeploy_tag.tier["std"].canonical_tag_name, octopusdeploy_tag.tier["prem"].canonical_tag_name],
    each.value.env == "prod" ? [] : [octopusdeploy_tag.tier["ent"].canonical_tag_name]
  )
}

# Dedicated (single-tenant) infrastructure for an Enterprise hospital
resource "octopusdeploy_cloud_region_deployment_target" "health_dedicated" {
  name                              = "medicore-staurelia-dedicated-prod"
  environments                      = [local.env.prod]
  roles                             = ["medicore-portal", "medicore-hl7"]
  default_worker_pool_id            = local.wp_linux
  tenanted_deployment_participation = "Tenanted"
  tenants                           = [octopusdeploy_tenant.hospital["st-aurelia"].id]
}
