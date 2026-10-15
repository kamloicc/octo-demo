# =============================================================================
# GOVERNANCE: deployment freezes (instance-level resources scoped to projects)
# =============================================================================

# Retail peak season: Black Friday -> Cyber Monday 2026.
# NOTE: provider v1.20 crashes on recurring_schedule (utc_offset_in_minutes bug),
# so these are one-off windows. Set "Repeats annually" in the UI if you want it.
resource "octopusdeploy_deployment_freeze" "peak_season" {
  name  = "[SE Demo] Retail Peak Season Freeze"
  start = "2026-11-26T00:00:00Z"
  end   = "2026-12-01T23:59:00Z"
}
resource "octopusdeploy_deployment_freeze_project" "peak_storefront" {
  deploymentfreeze_id = octopusdeploy_deployment_freeze.peak_season.id
  project_id          = octopusdeploy_project.cart_storefront.id
  environment_ids     = [local.env.prod]
}
resource "octopusdeploy_deployment_freeze_project" "peak_inventory" {
  deploymentfreeze_id = octopusdeploy_deployment_freeze.peak_season.id
  project_id          = octopusdeploy_project.cart_inventory.id
  environment_ids     = [local.env.prod]
}

# Finance year-end close window, 2026/27 (Prod + DR only)
resource "octopusdeploy_deployment_freeze" "fin_year_end" {
  name  = "[SE Demo] FinTrust Year-End Close"
  start = "2026-12-30T18:00:00Z"
  end   = "2027-01-03T06:00:00Z"
}
resource "octopusdeploy_deployment_freeze_project" "fin_payments" {
  deploymentfreeze_id = octopusdeploy_deployment_freeze.fin_year_end.id
  project_id          = octopusdeploy_project.fin_payments.id
  environment_ids     = [local.env.prod, local.env.dr]
}
resource "octopusdeploy_deployment_freeze_project" "fin_coredb" {
  deploymentfreeze_id = octopusdeploy_deployment_freeze.fin_year_end.id
  project_id          = octopusdeploy_project.fin_coredb.id
  environment_ids     = [local.env.prod, local.env.dr]
}

# Healthcare: tenant-specific freeze (one hospital during an EHR migration)
resource "octopusdeploy_deployment_freeze" "lakeside_ehr" {
  name  = "[SE Demo] Lakeside EHR Migration Weekend"
  start = "2026-12-12T00:00:00Z"
  end   = "2026-12-14T06:00:00Z"
}
resource "octopusdeploy_deployment_freeze_tenant" "lakeside_portal" {
  deploymentfreeze_id = octopusdeploy_deployment_freeze.lakeside_ehr.id
  tenant_id           = octopusdeploy_tenant.hospital["lakeside"].id
  project_id          = octopusdeploy_project.medicore_portal.id
  environment_id      = local.env.prod
  depends_on          = [octopusdeploy_tenant_project.hospital]
}
