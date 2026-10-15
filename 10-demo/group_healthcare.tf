# =============================================================================
# HEALTHCARE - MediCore Health
# Features: multi-tenancy, tenant tags, tenant project + common variables,
# shared vs dedicated tenanted infrastructure, release rings via channels,
# tenanted runbooks, tenant-scoped RBAC, HIPAA approvals & audit artifacts.
# =============================================================================

locals {
  hospitals = {
    "st-aurelia"  = { name = "St. Aurelia Medical Center", region = "na", tier = "ent", ring = "canary", sub = "staurelia", email = "oncall@staurelia.example" }
    "lakeside"    = { name = "Lakeside Children's Hospital", region = "na", tier = "prem", ring = "early", sub = "lakeside", email = "it@lakeside.example" }
    "nordvik"     = { name = "Nordvik University Hospital", region = "emea", tier = "prem", ring = "ga", sub = "nordvik", email = "drift@nordvik.example" }
    "harbour-bay" = { name = "Harbour Bay Clinic", region = "apac", tier = "std", ring = "ga", sub = "harbourbay", email = "ops@harbourbay.example" }
    "riverside"   = { name = "Riverside Community Health", region = "na", tier = "std", ring = "ga", sub = "riverside", email = "help@riverside.example" }
  }
  residency      = { na = "us-east", emea = "eu-north", apac = "ap-southeast" }
  health_tenv    = [local.env.test, local.env.staging, local.env.prod]
  health_projects = {
    portal = octopusdeploy_project.medicore_portal.id
    hl7    = octopusdeploy_project.medicore_hl7.id
  }
}

resource "octopusdeploy_tenant" "hospital" {
  for_each    = local.hospitals
  name        = each.value.name
  description = "Hospital tenant (${upper(each.value.region)}, ${each.value.tier})"
  tenant_tags = [
    octopusdeploy_tag.region[each.value.region].canonical_tag_name,
    octopusdeploy_tag.tier[each.value.tier].canonical_tag_name,
    octopusdeploy_tag.ring[each.value.ring].canonical_tag_name,
  ]
}

resource "octopusdeploy_tenant_project" "hospital" {
  for_each = { for p in setproduct(keys(local.hospitals), keys(local.health_projects)) : "${p[0]}-${p[1]}" => { tenant = p[0], project = p[1] } }

  tenant_id       = octopusdeploy_tenant.hospital[each.value.tenant].id
  project_id      = local.health_projects[each.value.project]
  environment_ids = local.health_tenv
}

# --- Patient Portal ----------------------------------------------------------
resource "octopusdeploy_project" "medicore_portal" {
  name                              = "MediCore - Patient Portal"
  slug                              = "medicore-patient-portal"
  description                       = "Tenanted web portal for hospitals. Dev is untenanted; Test/Staging/Prod are per hospital."
  project_group_id                  = octopusdeploy_project_group.healthcare.id
  lifecycle_id                      = octopusdeploy_lifecycle.regulated.id
  tenanted_deployment_participation = "TenantedOrUntenanted"
  default_guided_failure_mode       = "EnvironmentDefault"
  project_tags                      = [octopusdeploy_tag.compliance["hipaa"].canonical_tag_name, octopusdeploy_tag.compliance["gdpr"].canonical_tag_name]
  included_library_variable_sets = [
    octopusdeploy_library_variable_set.notifications.id,
    octopusdeploy_library_variable_set.observability.id,
    octopusdeploy_library_variable_set.demo_controls.id,
    octopusdeploy_library_variable_set.hospital.id,
  ]
  release_notes_template = "Release #{Octopus.Release.Number}\n#{each workItem in Octopus.Release.WorkItems}- #{workItem.Id}: #{workItem.Description}\n#{/each}"
  connectivity_policy {
    allow_deployments_to_no_targets = true
    skip_machine_behavior           = "SkipUnavailableMachines"
    exclude_unhealthy_targets       = true
  }
  template {
    name             = "Hospital.Subdomain"
    label            = "Portal subdomain"
    help_text        = "e.g. staurelia -> staurelia.medicore.health"
    display_settings = { "Octopus.ControlType" = "SingleLineText" }
  }
  template {
    name             = "Hospital.DatabaseName"
    label            = "Tenant database name"
    display_settings = { "Octopus.ControlType" = "SingleLineText" }
  }
}

locals {
  portal_tpl = { for t in octopusdeploy_project.medicore_portal.template : t.name => t.id }
}

resource "octopusdeploy_tenant_project_variable" "subdomain" {
  for_each    = local.hospitals
  tenant_id   = octopusdeploy_tenant.hospital[each.key].id
  project_id  = octopusdeploy_project.medicore_portal.id
  template_id = local.portal_tpl["Hospital.Subdomain"]
  value       = each.value.sub
  scope { environment_ids = local.health_tenv }
  depends_on = [octopusdeploy_tenant_project.hospital]
}
resource "octopusdeploy_tenant_project_variable" "dbname" {
  for_each    = local.hospitals
  tenant_id   = octopusdeploy_tenant.hospital[each.key].id
  project_id  = octopusdeploy_project.medicore_portal.id
  template_id = local.portal_tpl["Hospital.DatabaseName"]
  value       = "portal_${replace(each.key, "-", "_")}"
  scope { environment_ids = local.health_tenv }
  depends_on = [octopusdeploy_tenant_project.hospital]
}

resource "octopusdeploy_tenant_common_variable" "contact" {
  for_each                = local.hospitals
  tenant_id               = octopusdeploy_tenant.hospital[each.key].id
  library_variable_set_id = octopusdeploy_library_variable_set.hospital.id
  template_id             = octopusdeploy_library_variable_set.hospital.template_ids["Hospital.ContactEmail"]
  value                   = each.value.email
  depends_on              = [octopusdeploy_tenant_project.hospital]
}
resource "octopusdeploy_tenant_common_variable" "residency" {
  for_each                = local.hospitals
  tenant_id               = octopusdeploy_tenant.hospital[each.key].id
  library_variable_set_id = octopusdeploy_library_variable_set.hospital.id
  template_id             = octopusdeploy_library_variable_set.hospital.template_ids["Hospital.DataResidency"]
  value                   = local.residency[each.value.region]
  depends_on              = [octopusdeploy_tenant_project.hospital]
}
resource "octopusdeploy_tenant_common_variable" "ehr_key" {
  for_each                = local.hospitals
  tenant_id               = octopusdeploy_tenant.hospital[each.key].id
  library_variable_set_id = octopusdeploy_library_variable_set.hospital.id
  template_id             = octopusdeploy_library_variable_set.hospital.template_ids["Hospital.EhrApiKey"]
  value                   = "ehr-${each.key}-demo-secret"
  depends_on              = [octopusdeploy_tenant_project.hospital]
}

resource "octopusdeploy_variable" "portal_url" {
  owner_id = octopusdeploy_project.medicore_portal.id
  name     = "App.Url"
  type     = "String"
  value    = "https://#{Hospital.Subdomain | Default 'dev'}.#{Octopus.Environment.Name | ToLower}.medicore.health"
}
resource "octopusdeploy_variable" "portal_profile_canary" {
  owner_id = octopusdeploy_project.medicore_portal.id
  name     = "App.FeatureFlags"
  type     = "String"
  value    = "new-appointments-ui=on,telehealth-v2=on"
  scope { tenant_tags = [octopusdeploy_tag.ring["canary"].canonical_tag_name, octopusdeploy_tag.ring["early"].canonical_tag_name] }
}
resource "octopusdeploy_variable" "portal_profile_ga" {
  owner_id = octopusdeploy_project.medicore_portal.id
  name     = "App.FeatureFlags"
  type     = "String"
  value    = "new-appointments-ui=off,telehealth-v2=off"
}

# Release ring channel: only Canary + Early Adopter hospitals can receive it
resource "octopusdeploy_channel" "portal_preview" {
  name         = "Preview Ring"
  description  = "Early releases for Canary and Early Adopter hospitals only."
  project_id   = octopusdeploy_project.medicore_portal.id
  lifecycle_id = octopusdeploy_lifecycle.regulated.id
  tenant_tags  = [octopusdeploy_tag.ring["canary"].canonical_tag_name, octopusdeploy_tag.ring["early"].canonical_tag_name]
}

resource "octopusdeploy_process" "medicore_portal" {
  project_id = octopusdeploy_project.medicore_portal.id
}
resource "octopusdeploy_process_step" "portal_approval" {
  process_id   = octopusdeploy_process.medicore_portal.id
  name         = "HIPAA change approval"
  type         = "Octopus.Manual"
  environments = [local.env.prod]
  execution_properties = {
    "Octopus.Action.RunOnServer"                     = "true"
    "Octopus.Action.Manual.Instructions"             = "Confirm PHI impact assessment is attached for #{Octopus.Deployment.Tenant.Name}."
    "Octopus.Action.Manual.BlockConcurrentDeployments" = "False"
    "Octopus.Action.Manual.ResponsibleTeamIds"       = octopusdeploy_team.health_ops.id
  }
}
resource "octopusdeploy_process_step" "portal_deploy" {
  process_id     = octopusdeploy_process.medicore_portal.id
  name           = "Deploy Patient Portal"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  properties     = { "Octopus.Action.TargetRoles" = "medicore-portal" }
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/deploy-app.sh")
  })
}
resource "octopusdeploy_process_templated_step" "portal_smoke" {
  process_id       = octopusdeploy_process.medicore_portal.id
  name             = "Smoke test portal"
  template_id      = octopusdeploy_step_template.smoke.id
  template_version = octopusdeploy_step_template.smoke.version
  worker_pool_id   = local.wp_linux
  execution_properties = { "Octopus.Action.RunOnServer" = "true" }
  parameters       = { "Smoke.Url" = "#{App.Url}" }
}
resource "octopusdeploy_process_templated_step" "portal_notify" {
  process_id       = octopusdeploy_process.medicore_portal.id
  name             = "Notify hospital IT"
  template_id      = octopusdeploy_step_template.notify.id
  template_version = octopusdeploy_step_template.notify.version
  worker_pool_id   = local.wp_linux
  condition        = "Always"
  execution_properties = { "Octopus.Action.RunOnServer" = "true" }
  parameters = {
    "Notify.Template.Channel" = "#{Hospital.ContactEmail | Default '#medicore-dev'}"
    "Notify.Template.Message" = "Portal #{Octopus.Release.Number} -> #{Octopus.Deployment.Tenant.Name | Default 'untenanted'} (#{Octopus.Environment.Name}): #{Octopus.Deployment.Error | Default 'SUCCESS'}"
  }
}
resource "octopusdeploy_process_steps_order" "medicore_portal" {
  process_id = octopusdeploy_process.medicore_portal.id
  steps = [
    octopusdeploy_process_step.portal_approval.id,
    octopusdeploy_process_step.portal_deploy.id,
    octopusdeploy_process_templated_step.portal_smoke.id,
    octopusdeploy_process_templated_step.portal_notify.id,
  ]
}

# Tenanted runbooks
resource "octopusdeploy_runbook" "portal_restart" {
  project_id         = octopusdeploy_project.medicore_portal.id
  name               = "Restart Portal Services"
  description        = "Self-service restart for Hospital Ops (Runbook consumer role)."
  multi_tenancy_mode = "Tenanted"
  environment_scope  = "All"
  runbook_tags       = [octopusdeploy_tag.runbook_type["maint"].canonical_tag_name]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_process" "portal_restart" {
  project_id = octopusdeploy_project.medicore_portal.id
  runbook_id = octopusdeploy_runbook.portal_restart.id
}
resource "octopusdeploy_process_step" "portal_restart" {
  process_id     = octopusdeploy_process.portal_restart.id
  name           = "Rolling restart"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  properties     = { "Octopus.Action.TargetRoles" = "medicore-portal", "Octopus.Action.MaxParallelism" = "1" }
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/runbook-generic.sh") })
}

resource "octopusdeploy_runbook" "portal_audit" {
  project_id         = octopusdeploy_project.medicore_portal.id
  name               = "Export HIPAA Access Audit"
  description        = "Produces an access audit artifact per hospital."
  multi_tenancy_mode = "Tenanted"
  environment_scope  = "Specified"
  environments       = [local.env.prod]
  runbook_tags       = [octopusdeploy_tag.runbook_type["maint"].canonical_tag_name]
}
resource "octopusdeploy_process" "portal_audit" {
  project_id = octopusdeploy_project.medicore_portal.id
  runbook_id = octopusdeploy_runbook.portal_audit.id
}
resource "octopusdeploy_process_step" "portal_audit" {
  process_id     = octopusdeploy_process.portal_audit.id
  name           = "Export audit log"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      echo "user,patient_id,action,timestamp" > access-audit.csv
      for i in 1 2 3 4 5; do echo "clin_$i,P-00$i,VIEW_RECORD,$(date -u +%FT%TZ)" >> access-audit.csv; done
      new_octopusartifact "$(pwd)/access-audit.csv" "hipaa-audit-#{Octopus.Deployment.Tenant.Name}.csv"
      write_highlight "Audit exported for #{Octopus.Deployment.Tenant.Name} (residency: #{Hospital.DataResidency})"
    EOT
  })
}

# --- HL7 Integration Engine --------------------------------------------------
resource "octopusdeploy_project" "medicore_hl7" {
  name                              = "MediCore - HL7 Integration Engine"
  slug                              = "medicore-hl7-integration-engine"
  description                       = "Tenanted interface engine (HL7 / FHIR) per hospital."
  project_group_id                  = octopusdeploy_project_group.healthcare.id
  lifecycle_id                      = octopusdeploy_lifecycle.standard.id
  tenanted_deployment_participation = "Tenanted"
  project_tags                      = [octopusdeploy_tag.compliance["hipaa"].canonical_tag_name]
  included_library_variable_sets    = [octopusdeploy_library_variable_set.notifications.id, octopusdeploy_library_variable_set.hospital.id, octopusdeploy_script_module.helpers.id, octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_process" "medicore_hl7" {
  project_id = octopusdeploy_project.medicore_hl7.id
}
resource "octopusdeploy_process_step" "hl7_deploy" {
  process_id     = octopusdeploy_process.medicore_hl7.id
  name           = "Deploy interface engine"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  properties     = { "Octopus.Action.TargetRoles" = "medicore-hl7" }
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/deploy-app.sh") })
}
resource "octopusdeploy_process_step" "hl7_validate" {
  process_id     = octopusdeploy_process.medicore_hl7.id
  name           = "Validate HL7 channels"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      demo_banner "HL7 validation for #{Octopus.Deployment.Tenant.Name}"
      for ch in ADT^A01 ORM^O01 ORU^R01 SIU^S12; do echo "  channel $ch ... OK"; sleep 1; done
      demo_wait_for "FHIR R4 endpoint" 2
    EOT
  })
}
resource "octopusdeploy_process_steps_order" "medicore_hl7" {
  process_id = octopusdeploy_process.medicore_hl7.id
  steps      = [octopusdeploy_process_step.hl7_deploy.id, octopusdeploy_process_step.hl7_validate.id]
}

resource "octopusdeploy_runbook" "hl7_replay" {
  project_id         = octopusdeploy_project.medicore_hl7.id
  name               = "Replay Failed HL7 Messages"
  multi_tenancy_mode = "Tenanted"
  environment_scope  = "All"
  runbook_tags       = [octopusdeploy_tag.runbook_type["incident"].canonical_tag_name]
}
resource "octopusdeploy_process" "hl7_replay" {
  project_id = octopusdeploy_project.medicore_hl7.id
  runbook_id = octopusdeploy_runbook.hl7_replay.id
}
resource "octopusdeploy_process_step" "hl7_replay" {
  process_id     = octopusdeploy_process.hl7_replay.id
  name           = "Replay dead-letter queue"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/runbook-generic.sh") })
}
resource "octopusdeploy_variable" "hl7_reason_prompt" {
  owner_id = octopusdeploy_project.medicore_hl7.id
  name     = "Runbook.Reason"
  type     = "String"
  value    = ""
  prompt {
    label       = "Incident number / reason"
    is_required = true
    display_settings { control_type = "SingleLineText" }
  }
  scope { processes = [octopusdeploy_runbook.hl7_replay.id] }
}
