# =============================================================================
# MANUFACTURING - Forge Industries
# Features: many edge targets across plants, target-tag scoped variables,
# rolling deployment (window 2), canary-then-fleet rollout, go/no-go gate,
# deployment target trigger (auto-deploy new plant gateways), Windows workers
# + PowerShell, diagnostics runbook with artifacts.
# =============================================================================

# --- MES Plant Services ------------------------------------------------------
resource "octopusdeploy_project" "forge_mes" {
  name                           = "Forge - MES Plant Services"
  slug                           = "forge-mes-plant-services"
  description                    = "Manufacturing Execution System services on plant-floor edge gateways (4 plants x 2 lines)."
  project_group_id               = octopusdeploy_project_group.manufacturing.id
  lifecycle_id                   = octopusdeploy_lifecycle.standard.id
  project_tags                   = [octopusdeploy_tag.compliance["iec"].canonical_tag_name, octopusdeploy_tag.compliance["iso"].canonical_tag_name]
  included_library_variable_sets = [octopusdeploy_library_variable_set.notifications.id, octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
    skip_machine_behavior           = "SkipUnavailableMachines" # edge sites go offline
    exclude_unhealthy_targets       = true
  }
}

# Role-scoped variables: each plant gets its own settings
resource "octopusdeploy_variable" "forge_plant_tz" {
  for_each = { detroit = "America/Detroit", monterrey = "America/Monterrey", stuttgart = "Europe/Berlin", pune = "Asia/Kolkata" }
  owner_id = octopusdeploy_project.forge_mes.id
  name     = "Plant.TimeZone"
  type     = "String"
  value    = each.value
  scope { roles = ["plant-${each.key}"] }
}
resource "octopusdeploy_variable" "forge_plant_shift" {
  owner_id = octopusdeploy_project.forge_mes.id
  name     = "App.ConfigProfile"
  type     = "String"
  value    = "plant=#{Octopus.Machine.Name} tz=#{Plant.TimeZone | Default 'UTC'}"
}

resource "octopusdeploy_process" "forge_mes" {
  project_id = octopusdeploy_project.forge_mes.id
}
resource "octopusdeploy_process_step" "forge_mes_window" {
  process_id     = octopusdeploy_process.forge_mes.id
  name           = "Check production line is idle"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  properties     = { "Octopus.Action.TargetRoles" = "forge-mes-edge" }
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      echo "Querying PLC state for #{Octopus.Machine.Name} (tz #{Plant.TimeZone | Default 'UTC'})"
      echo "Line state: CHANGEOVER (safe to deploy)"
    EOT
  })
}
resource "octopusdeploy_process_step" "forge_mes_deploy" {
  process_id     = octopusdeploy_process.forge_mes.id
  name           = "Rolling deploy to edge gateways"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  properties = {
    "Octopus.Action.TargetRoles"    = "forge-mes-edge"
    "Octopus.Action.MaxParallelism" = "2"
  }
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/deploy-app.sh") })
}
resource "octopusdeploy_process_steps_order" "forge_mes" {
  process_id = octopusdeploy_process.forge_mes.id
  steps      = [octopusdeploy_process_step.forge_mes_window.id, octopusdeploy_process_step.forge_mes_deploy.id]
}

# Auto-deploy the current release when a new plant gateway comes online
resource "octopusdeploy_project_deployment_target_trigger" "forge_new_gateway" {
  name             = "Auto-deploy new edge gateways"
  project_id       = octopusdeploy_project.forge_mes.id
  event_groups     = ["MachineAvailableForDeployment"]
  roles            = ["forge-mes-edge"]
  environment_ids  = [local.env.prod]
  should_redeploy  = false
}

resource "octopusdeploy_runbook" "forge_diag" {
  project_id        = octopusdeploy_project.forge_mes.id
  name              = "Collect Gateway Diagnostics"
  environment_scope = "All"
  runbook_tags      = [octopusdeploy_tag.runbook_type["incident"].canonical_tag_name]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_process" "forge_diag" {
  project_id = octopusdeploy_project.forge_mes.id
  runbook_id = octopusdeploy_runbook.forge_diag.id
}
resource "octopusdeploy_process_step" "forge_diag" {
  process_id     = octopusdeploy_process.forge_diag.id
  name           = "Collect logs"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  properties     = { "Octopus.Action.TargetRoles" = "forge-mes-edge" }
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      printf "gateway=#{Octopus.Machine.Name}\ncpu=37%%\nmem=61%%\nopcua=connected\nlast_error=none\n" > diag.txt
      new_octopusartifact "$(pwd)/diag.txt" "diag-#{Octopus.Machine.Name}.txt"
    EOT
  })
}

# --- Edge Firmware Rollout (canary) -----------------------------------------
resource "octopusdeploy_project" "forge_firmware" {
  name                           = "Forge - Edge Firmware Rollout"
  slug                           = "forge-edge-firmware-rollout"
  description                    = "Canary first (Detroit line 1), automated analysis, go/no-go, then the rest of the fleet."
  project_group_id               = octopusdeploy_project_group.manufacturing.id
  lifecycle_id                   = octopusdeploy_lifecycle.standard.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.demo_controls.id, octopusdeploy_library_variable_set.observability.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_process" "forge_firmware" {
  project_id = octopusdeploy_project.forge_firmware.id
}
resource "octopusdeploy_process_step" "fw_canary" {
  process_id     = octopusdeploy_process.forge_firmware.id
  name           = "Flash canary gateway"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  properties     = { "Octopus.Action.TargetRoles" = "forge-canary" }
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/deploy-app.sh") })
}
resource "octopusdeploy_process_step" "fw_analysis" {
  process_id     = octopusdeploy_process.forge_firmware.id
  name           = "Canary analysis"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/canary-analysis.sh") })
}
resource "octopusdeploy_process_step" "fw_gate" {
  process_id   = octopusdeploy_process.forge_firmware.id
  name         = "Go-No-Go for fleet"
  type         = "Octopus.Manual"
  environments = [local.env.prod]
  execution_properties = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Manual.Instructions" = "Canary healthy for 5 minutes. Proceed with remaining plants?"
  }
}
resource "octopusdeploy_process_step" "fw_fleet" {
  process_id     = octopusdeploy_process.forge_firmware.id
  name           = "Flash remaining fleet"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  properties = {
    "Octopus.Action.TargetRoles"    = "forge-mes-edge"
    "Octopus.Action.MaxParallelism" = "3"
  }
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/deploy-app.sh") })
}
resource "octopusdeploy_process_steps_order" "forge_firmware" {
  process_id = octopusdeploy_process.forge_firmware.id
  steps      = [octopusdeploy_process_step.fw_canary.id, octopusdeploy_process_step.fw_analysis.id, octopusdeploy_process_step.fw_gate.id, octopusdeploy_process_step.fw_fleet.id]
}

# --- SCADA Gateway (Windows) -------------------------------------------------
resource "octopusdeploy_project" "forge_scada" {
  name             = "Forge - SCADA Gateway (Windows)"
  slug             = "forge-scada-gateway"
  description      = "Windows service with config transforms. Runs on Windows dynamic workers (swap for Tentacles later)."
  project_group_id = octopusdeploy_project_group.manufacturing.id
  lifecycle_id     = octopusdeploy_lifecycle.standard.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_variable" "forge_scada_svc" {
  owner_id = octopusdeploy_project.forge_scada.id
  name     = "Service.Name"
  type     = "String"
  value    = "ForgeScadaGateway"
}
resource "octopusdeploy_process" "forge_scada" {
  project_id = octopusdeploy_project.forge_scada.id
}
resource "octopusdeploy_process_step" "forge_scada" {
  process_id     = octopusdeploy_process.forge_scada.id
  name           = "Deploy Windows service"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_windows
  execution_properties = merge(local.pwsh, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/deploy-windows.ps1") })
}
