# =============================================================================
# PLATFORM ENGINEERING
# Features: infrastructure provisioning runbooks (Terraform simulated) with
# prompted Select variables, teardown, release orchestration with
# "Deploy a Release" steps (release train), worker pool variables.
# =============================================================================

resource "octopusdeploy_project" "plat_lz" {
  name             = "Platform - Landing Zone Provisioning"
  slug             = "platform-landing-zone"
  description      = "Self-service environment provisioning and teardown runbooks."
  project_group_id = octopusdeploy_project_group.platform.id
  lifecycle_id     = octopusdeploy_lifecycle.standard.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_variable" "plat_size" {
  owner_id = octopusdeploy_project.plat_lz.id
  name     = "Infra.Size"
  type     = "String"
  value    = "small"
  prompt {
    label       = "Environment size"
    is_required = true
    display_settings {
      control_type = "Select"
      select_option {
        value        = "small"
        display_name = "Small (3 nodes)"
      }
      select_option {
        value        = "medium"
        display_name = "Medium (6 nodes)"
      }
      select_option {
        value        = "large"
        display_name = "Large (12 nodes)"
      }
    }
  }
  scope { processes = [octopusdeploy_runbook.plat_provision.id] }
}
resource "octopusdeploy_variable" "plat_nodes" {
  owner_id = octopusdeploy_project.plat_lz.id
  name     = "Infra.NodeCount"
  type     = "String"
  value    = "#{if Infra.Size == \"large\"}12#{else}#{if Infra.Size == \"medium\"}6#{else}3#{/if}#{/if}"
}
resource "octopusdeploy_variable" "plat_pool" {
  owner_id = octopusdeploy_project.plat_lz.id
  name     = "Infra.WorkerPool"
  type     = "WorkerPool"
  value    = local.wp_linux
}

resource "octopusdeploy_runbook" "plat_provision" {
  project_id        = octopusdeploy_project.plat_lz.id
  name              = "Provision Environment"
  environment_scope = "All"
  runbook_tags      = [octopusdeploy_tag.runbook_type["prov"].canonical_tag_name]
}
resource "octopusdeploy_process" "plat_provision" {
  project_id = octopusdeploy_project.plat_lz.id
  runbook_id = octopusdeploy_runbook.plat_provision.id
}
resource "octopusdeploy_process_step" "plat_provision" {
  process_id           = octopusdeploy_process.plat_provision.id
  name                 = "Terraform apply"
  type                 = "Octopus.Script"
  worker_pool_variable = "Infra.WorkerPool"
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/provision-infra.sh") })
}

resource "octopusdeploy_runbook" "plat_teardown" {
  project_id        = octopusdeploy_project.plat_lz.id
  name              = "Teardown Environment"
  environment_scope = "Specified"
  environments      = [local.env.dev, local.env.test]
  runbook_tags      = [octopusdeploy_tag.runbook_type["prov"].canonical_tag_name]
}
resource "octopusdeploy_process" "plat_teardown" {
  project_id = octopusdeploy_project.plat_lz.id
  runbook_id = octopusdeploy_runbook.plat_teardown.id
}
resource "octopusdeploy_process_step" "plat_teardown" {
  process_id     = octopusdeploy_process.plat_teardown.id
  name           = "Terraform destroy"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = "echo 'terraform destroy -auto-approve'; sleep 2; write_highlight 'Destroyed #{Octopus.Environment.Name} landing zone'"
  })
}

# --- Release train: orchestrate the FinTrust projects in order --------------
resource "octopusdeploy_project" "plat_train" {
  count            = var.enable_release_train ? 1 : 0
  name             = "Platform - FinTrust Release Train"
  slug             = "platform-fintrust-release-train"
  description      = "Deploys Core Banking DB, then Payments API and Fraud Model, using 'Deploy a Release' steps. Release versions are chosen when creating the train release."
  project_group_id = octopusdeploy_project_group.platform.id
  lifecycle_id     = octopusdeploy_lifecycle.regulated.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_process" "plat_train" {
  count      = var.enable_release_train ? 1 : 0
  project_id = octopusdeploy_project.plat_train[0].id
}

# The built-in "releases" feed has a per-space ID (e.g. Feeds-1110)
data "octopusdeploy_feeds" "releases" {
  feed_type = "OctopusProject"
  take      = 1
}

locals {
  train = var.enable_release_train ? {
    "1-coredb"   = { name = "Deploy Core Banking Database", project = octopusdeploy_project.fin_coredb.id, start = "StartAfterPrevious" }
    "2-payments" = { name = "Deploy Payments API", project = octopusdeploy_project.fin_payments.id, start = "StartAfterPrevious" }
    "3-fraud"    = { name = "Deploy Fraud Scoring Model", project = octopusdeploy_project.fin_fraud.id, start = "StartWithPrevious" }
  } : {}
}
resource "octopusdeploy_process_step" "plat_train" {
  for_each      = local.train
  process_id    = octopusdeploy_process.plat_train[0].id
  name          = each.value.name
  type          = "Octopus.DeployRelease"
  start_trigger = each.value.start
  primary_package = {
    package_id           = each.value.project
    feed_id              = data.octopusdeploy_feeds.releases.feeds[0].id
    acquisition_location = "NotAcquired"
  }
  execution_properties = {
    "Octopus.Action.DeployRelease.ProjectId"           = each.value.project
    "Octopus.Action.DeployRelease.DeploymentCondition" = "IfNotCurrentVersion"
    "Octopus.Action.RunOnServer"                       = "true"
  }
}
resource "octopusdeploy_process_steps_order" "plat_train" {
  count      = var.enable_release_train ? 1 : 0
  process_id = octopusdeploy_process.plat_train[0].id
  steps      = [for k in sort(keys(local.train)) : octopusdeploy_process_step.plat_train[k].id]
}
