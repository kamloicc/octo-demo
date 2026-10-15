# =============================================================================
# LIBRARY: variable sets, script modules, step templates, teams (RBAC)
# =============================================================================

# --- Library variable sets ---------------------------------------------------
resource "octopusdeploy_library_variable_set" "notifications" {
  name        = "Global - Notifications"
  description = "Shared notification settings. Demo: library variable sets reused by every project."
}
resource "octopusdeploy_variable" "notify_channel" {
  owner_id = octopusdeploy_library_variable_set.notifications.id
  name     = "Notify.Channel"
  type     = "String"
  value    = "#deployments"
}
resource "octopusdeploy_variable" "notify_channel_prod" {
  owner_id = octopusdeploy_library_variable_set.notifications.id
  name     = "Notify.Channel"
  type     = "String"
  value    = "#prod-releases"
  scope { environments = [local.env.prod, local.env.dr] }
}
resource "octopusdeploy_variable" "notify_webhook" {
  owner_id        = octopusdeploy_library_variable_set.notifications.id
  name            = "Notify.WebhookUrl"
  type            = "Sensitive"
  is_sensitive    = true
  sensitive_value = "https://hooks.slack.com/services/T000/B000/REPLACE-ME"
}

resource "octopusdeploy_library_variable_set" "observability" {
  name        = "Global - Observability"
  description = "Endpoints used by smoke tests and canary analysis."
}
resource "octopusdeploy_variable" "obs_url" {
  owner_id = octopusdeploy_library_variable_set.observability.id
  name     = "Observability.Url"
  type     = "String"
  value    = "https://metrics.#{Octopus.Environment.Name | ToLower}.demo.internal"
}

resource "octopusdeploy_library_variable_set" "demo_controls" {
  name        = "Demo Controls"
  description = "Prompted switches to force failures live (guided failure, failure analysis, rollback, Recovery Agent)."
}
resource "octopusdeploy_variable" "demo_fail_smoke" {
  owner_id = octopusdeploy_library_variable_set.demo_controls.id
  name     = "Demo.FailSmokeTest"
  type     = "String"
  value    = "False"
  prompt {
    label       = "Fail the smoke test?"
    description = "Demo switch: forces the smoke test to fail."
    is_required = false
    display_settings { control_type = "Checkbox" }
  }
}
resource "octopusdeploy_variable" "demo_fail_deploy" {
  owner_id = octopusdeploy_library_variable_set.demo_controls.id
  name     = "Demo.FailDeployment"
  type     = "String"
  value    = "False"
  prompt {
    label       = "Fail the deployment step?"
    description = "Demo switch: the main deploy step fails (works in every project). Used by seed-history.py."
    is_required = false
    display_settings { control_type = "Checkbox" }
  }
}
resource "octopusdeploy_variable" "demo_fail_scan" {
  owner_id = octopusdeploy_library_variable_set.demo_controls.id
  name     = "Demo.FailSecurityScan"
  type     = "String"
  value    = "False"
  prompt {
    label       = "Fail the security scan?"
    is_required = false
    display_settings { control_type = "Checkbox" }
  }
}
resource "octopusdeploy_variable" "demo_fail_canary" {
  owner_id = octopusdeploy_library_variable_set.demo_controls.id
  name     = "Demo.FailCanary"
  type     = "String"
  value    = "False"
  prompt {
    label       = "Fail the canary analysis?"
    is_required = false
    display_settings { control_type = "Checkbox" }
  }
}

# Tenant "common variables" via variable templates on a library set
resource "octopusdeploy_library_variable_set" "hospital" {
  name        = "Healthcare - Hospital Settings"
  description = "Per-tenant (hospital) settings. Demo: common tenant variables."
  template {
    name             = "Hospital.ContactEmail"
    label            = "On-call contact email"
    display_settings = { "Octopus.ControlType" = "SingleLineText" }
  }
  template {
    name             = "Hospital.DataResidency"
    label            = "Data residency region"
    default_value    = "us-east"
    display_settings = { "Octopus.ControlType" = "SingleLineText" }
  }
  template {
    name             = "Hospital.EhrApiKey"
    label            = "EHR API key"
    display_settings = { "Octopus.ControlType" = "Sensitive" }
  }
}

# --- Script module -----------------------------------------------------------
resource "octopusdeploy_script_module" "helpers" {
  name        = "Demo Helpers"
  description = "Reusable Bash functions. Demo: script modules shared across projects."
  script {
    syntax = "Bash"
    body   = <<-EOT
      # Usage: demo_banner "text"
      demo_banner() {
        echo "=================================================="
        echo " $1"
        echo "=================================================="
      }
      # Usage: demo_wait_for "service" seconds
      demo_wait_for() {
        echo "Waiting for $1 to become healthy..."; sleep "$2"; echo "$1 healthy"
      }
    EOT
  }
}

# --- Custom step templates ---------------------------------------------------
resource "octopusdeploy_step_template" "notify" {
  name            = "Demo - Send Release Notification"
  description     = "Posts a release notification (simulated Slack/Teams). Demo: custom step templates with parameters and versioning."
  action_type     = "Octopus.Script"
  step_package_id = "Octopus.Script"
  packages        = []
  parameters = [
    {
      id               = "6a6c2f0e-0b1d-4f49-9a52-000000000001"
      name             = "Notify.Template.Channel"
      label            = "Channel"
      help_text        = "Slack/Teams channel"
      default_value    = "#{Notify.Channel}"
      display_settings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      id               = "6a6c2f0e-0b1d-4f49-9a52-000000000002"
      name             = "Notify.Template.Message"
      label            = "Message"
      default_value    = "#{Octopus.Project.Name} #{Octopus.Release.Number} deployed to #{Octopus.Environment.Name}"
      display_settings = { "Octopus.ControlType" = "MultiLineText" }
    }
  ]
  properties = {
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "Bash"
    "Octopus.Action.Script.ScriptBody"   = <<-EOT
      echo "POST #{Notify.WebhookUrl} (masked)"
      echo "[#{Notify.Template.Channel}] #{Notify.Template.Message}"
      echo "Deployment link: #{Octopus.Web.ServerUri}#{Octopus.Web.DeploymentLink}"
      write_highlight "Notification sent to #{Notify.Template.Channel}"
    EOT
  }
}

resource "octopusdeploy_step_template" "smoke" {
  name            = "Demo - HTTP Smoke Test"
  description     = "Simulated HTTP smoke test. Honours Demo.FailSmokeTest."
  action_type     = "Octopus.Script"
  step_package_id = "Octopus.Script"
  packages        = []
  parameters = [
    {
      id               = "6a6c2f0e-0b1d-4f49-9a52-000000000011"
      name             = "Smoke.Url"
      label            = "URL to test"
      default_value    = "#{App.Url}"
      display_settings = { "Octopus.ControlType" = "SingleLineText" }
    }
  ]
  properties = {
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "Bash"
    "Octopus.Action.Script.ScriptBody"   = replace(file("${local.scripts}/smoke-test.sh"), "#{App.Url | Default 'https://example.com'}", "#{Smoke.Url}")
  }
}

# --- RBAC: teams scoped to project groups / environments ---------------------
data "octopusdeploy_user_roles" "deployer" {
  partial_name = "Project deployer"
  take         = 1
}
data "octopusdeploy_user_roles" "viewer" {
  partial_name = "Project viewer"
  take         = 1
}
data "octopusdeploy_user_roles" "runbook_consumer" {
  partial_name = "Runbook consumer"
  take         = 1
}
data "octopusdeploy_user_roles" "release_creator" {
  partial_name = "Release creator"
  take         = 1
}

locals {
  role = {
    deployer = data.octopusdeploy_user_roles.deployer.user_roles[0].id
    viewer   = data.octopusdeploy_user_roles.viewer.user_roles[0].id
    runbook  = data.octopusdeploy_user_roles.runbook_consumer.user_roles[0].id
    creator  = data.octopusdeploy_user_roles.release_creator.user_roles[0].id
  }
}

resource "octopusdeploy_team" "fin_engineers" {
  name        = "FinTrust - Engineers"
  description = "Can create releases and deploy to non-prod only. Demo: environment-scoped RBAC."
  space_id    = var.space_id
  users       = var.demo_user_ids
  user_role {
    space_id          = var.space_id
    user_role_id      = local.role.deployer
    project_group_ids = [octopusdeploy_project_group.finance.id]
    environment_ids   = [local.env.dev, local.env.test, local.env.staging]
  }
  user_role {
    space_id          = var.space_id
    user_role_id      = local.role.creator
    project_group_ids = [octopusdeploy_project_group.finance.id]
  }
}
resource "octopusdeploy_team" "fin_release_mgrs" {
  name        = "FinTrust - Release Managers"
  description = "Approve and deploy to Production. Demo: separation of duties + manual intervention responsible team."
  space_id    = var.space_id
  users       = var.demo_user_ids
  user_role {
    space_id          = var.space_id
    user_role_id      = local.role.deployer
    project_group_ids = [octopusdeploy_project_group.finance.id]
    environment_ids   = [local.env.prod, local.env.dr]
  }
}
resource "octopusdeploy_team" "health_ops" {
  name        = "MediCore - Hospital Ops"
  description = "Run runbooks only, for specific tenants. Demo: tenant-scoped runbook consumer."
  space_id    = var.space_id
  users       = var.demo_user_ids
  user_role {
    space_id          = var.space_id
    user_role_id      = local.role.runbook
    project_group_ids = [octopusdeploy_project_group.healthcare.id]
  }
}
resource "octopusdeploy_team" "civic_security" {
  name        = "CivicOne - Security Officers"
  description = "Second approver for Production (security sign-off)."
  space_id    = var.space_id
  users       = var.demo_user_ids
  user_role {
    space_id          = var.space_id
    user_role_id      = local.role.viewer
    project_group_ids = [octopusdeploy_project_group.public_sector.id]
  }
}
resource "octopusdeploy_team" "civic_cab" {
  name        = "CivicOne - Change Advisory Board"
  description = "First approver for Production (CAB sign-off)."
  space_id    = var.space_id
  users       = var.demo_user_ids
  user_role {
    space_id          = var.space_id
    user_role_id      = local.role.viewer
    project_group_ids = [octopusdeploy_project_group.public_sector.id]
  }
}
