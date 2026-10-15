# =============================================================================
# RETAIL - Cartwheel Commerce
# Features: container image package references (Docker Hub), external feed
# trigger (auto-create release on new image), channels with version rules
# (pre-release -> feature lifecycle), blue/green with output variables,
# approval before traffic switch, peak-season freeze (governance.tf),
# parallel steps, scheduled promotion trigger, live Config-as-Code conversion.
# =============================================================================

locals {
  podinfo_pkg = {
    package_id           = "stefanprodan/podinfo"
    feed_id              = octopusdeploy_docker_container_registry.ghcr.id # Docker Hub needs auth to list tags
    acquisition_location = "NotAcquired"
    properties           = { "Extract" = "False", "SelectionMode" = "immediate", "Purpose" = "" }
  }
}

# --- Storefront Web (blue/green) --------------------------------------------
resource "octopusdeploy_project" "cart_storefront" {
  name                           = "Cartwheel - Storefront Web"
  slug                           = "cartwheel-storefront-web"
  description                    = "Customer storefront. Blue/green on 2 prod nodes. Image: stefanprodan/podinfo (sample app)."
  project_group_id               = octopusdeploy_project_group.retail.id
  lifecycle_id                   = octopusdeploy_lifecycle.standard.id
  project_tags                   = [octopusdeploy_tag.compliance["pci"].canonical_tag_name, octopusdeploy_tag.compliance["gdpr"].canonical_tag_name]
  included_library_variable_sets = [octopusdeploy_library_variable_set.notifications.id, octopusdeploy_library_variable_set.observability.id, octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_variable" "cart_url" {
  owner_id = octopusdeploy_project.cart_storefront.id
  name     = "App.Url"
  type     = "String"
  value    = "https://#{Octopus.Environment.Name | ToLower}.shop.cartwheel.example"
}
resource "octopusdeploy_variable" "cart_url_prod" {
  owner_id = octopusdeploy_project.cart_storefront.id
  name     = "App.Url"
  type     = "String"
  value    = "https://shop.cartwheel.example"
  scope { environments = [local.env.prod] }
}
resource "octopusdeploy_variable" "cart_flags" {
  owner_id = octopusdeploy_project.cart_storefront.id
  name     = "App.FeatureFlags"
  type     = "String"
  value    = "one-click-checkout=on,ai-recommendations=on"
}
resource "octopusdeploy_variable" "cart_flags_prod" {
  owner_id = octopusdeploy_project.cart_storefront.id
  name     = "App.FeatureFlags"
  type     = "String"
  value    = "one-click-checkout=on,ai-recommendations=off"
  scope { environments = [local.env.prod] }
}
resource "octopusdeploy_variable" "cart_lb" {
  owner_id = octopusdeploy_project.cart_storefront.id
  name     = "LoadBalancer.Name"
  type     = "String"
  value    = "lb-storefront-#{Octopus.Environment.Name | ToLower}"
}

resource "octopusdeploy_process" "cart_storefront" {
  project_id = octopusdeploy_project.cart_storefront.id
}
resource "octopusdeploy_process_step" "cart_slot" {
  process_id     = octopusdeploy_process.cart_storefront.id
  name           = "Determine live slot"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/determine-slot.sh") })
}
resource "octopusdeploy_process_step" "cart_deploy" {
  process_id     = octopusdeploy_process.cart_storefront.id
  name           = "Deploy to idle slot"
  slug           = "deploy-to-idle-slot"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  properties     = { "Octopus.Action.TargetRoles" = "cartwheel-web" }
  packages       = { "app" = local.podinfo_pkg }
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/deploy-app.sh") })
}
resource "octopusdeploy_process_templated_step" "cart_smoke" {
  process_id           = octopusdeploy_process.cart_storefront.id
  name                 = "Smoke test idle slot"
  template_id          = octopusdeploy_step_template.smoke.id
  template_version     = octopusdeploy_step_template.smoke.version
  worker_pool_id       = local.wp_linux
  execution_properties = { "Octopus.Action.RunOnServer" = "true" }
  parameters           = { "Smoke.Url" = "#{App.Url}/#{Octopus.Action[Determine live slot].Output.IdleSlot}" }
}
resource "octopusdeploy_process_step" "cart_approve" {
  process_id   = octopusdeploy_process.cart_storefront.id
  name         = "Approve traffic switch"
  type         = "Octopus.Manual"
  environments = [local.env.prod]
  execution_properties = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Manual.Instructions" = "Idle slot #{Octopus.Action[Determine live slot].Output.IdleSlot} passed smoke tests. Switch production traffic?"
  }
}
resource "octopusdeploy_process_step" "cart_switch" {
  process_id     = octopusdeploy_process.cart_storefront.id
  name           = "Switch traffic"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/switch-traffic.sh") })
}
resource "octopusdeploy_process_step" "cart_rollback" {
  process_id     = octopusdeploy_process.cart_storefront.id
  name           = "Rollback traffic on failure"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  condition      = "Failure"
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = "write_warning \"Deployment failed - keeping #{Octopus.Action[Determine live slot].Output.LiveSlot} live, idle slot drained\""
  })
}
resource "octopusdeploy_process_steps_order" "cart_storefront" {
  process_id = octopusdeploy_process.cart_storefront.id
  steps = [
    octopusdeploy_process_step.cart_slot.id,
    octopusdeploy_process_step.cart_deploy.id,
    octopusdeploy_process_templated_step.cart_smoke.id,
    octopusdeploy_process_step.cart_approve.id,
    octopusdeploy_process_step.cart_switch.id,
    octopusdeploy_process_step.cart_rollback.id,
  ]
}

# Channels: stable images vs pre-release images
data "octopusdeploy_channels" "cart_default" {
  partial_name = "Default"
  project_id   = octopusdeploy_project.cart_storefront.id
  take         = 1
  depends_on   = [octopusdeploy_process_steps_order.cart_storefront]
}
resource "octopusdeploy_channel" "cart_feature" {
  name         = "Feature Preview"
  description  = "Pre-release image tags (e.g. 6.7.1-beta) go to Development only."
  project_id   = octopusdeploy_project.cart_storefront.id
  lifecycle_id = octopusdeploy_lifecycle.feature.id
  rule {
    tag = "^.+$"
    action_package {
      deployment_action = octopusdeploy_process_step.cart_deploy.name
      package_reference = "app"
    }
  }
  depends_on = [octopusdeploy_process_steps_order.cart_storefront]
}

# Auto-create a release when a new podinfo image tag is published
resource "octopusdeploy_external_feed_create_release_trigger" "cart_image" {
  name       = "New podinfo image"
  space_id   = var.space_id
  project_id = octopusdeploy_project.cart_storefront.id
  channel_id = data.octopusdeploy_channels.cart_default.channels[0].id
  package {
    deployment_action_slug = octopusdeploy_process_step.cart_deploy.slug
    package_reference      = "app"
  }
}

# --- Inventory Service (parallel steps, scheduled promotion, CaC candidate) --
resource "octopusdeploy_project" "cart_inventory" {
  name                           = "Cartwheel - Inventory Service"
  slug                           = "cartwheel-inventory-service"
  description                    = "API + background worker deployed in parallel. Convert to Config as Code live during demos."
  project_group_id               = octopusdeploy_project_group.retail.id
  lifecycle_id                   = octopusdeploy_lifecycle.standard.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.notifications.id, octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_process" "cart_inventory" {
  project_id = octopusdeploy_project.cart_inventory.id
}
resource "octopusdeploy_process_step" "inv_db" {
  process_id     = octopusdeploy_process.cart_inventory.id
  name           = "Migrate inventory DB"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/db-migrate.sh") })
}
resource "octopusdeploy_process_step" "inv_api" {
  process_id     = octopusdeploy_process.cart_inventory.id
  name           = "Deploy inventory API"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/deploy-app.sh") })
}
resource "octopusdeploy_process_step" "inv_worker" {
  process_id     = octopusdeploy_process.cart_inventory.id
  name           = "Deploy stock-sync worker"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  start_trigger  = "StartWithPrevious" # runs in parallel with the API step
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/deploy-app.sh") })
}
resource "octopusdeploy_process_steps_order" "cart_inventory" {
  process_id = octopusdeploy_process.cart_inventory.id
  steps      = [octopusdeploy_process_step.inv_db.id, octopusdeploy_process_step.inv_api.id, octopusdeploy_process_step.inv_worker.id]
}
resource "octopusdeploy_project_scheduled_trigger" "inv_nightly_promote" {
  count       = var.enable_scheduled_triggers ? 1 : 0
  space_id    = var.space_id
  name        = "Nightly promote Dev to Test"
  description = "Promotes the latest successful Dev release to Test every weekday at 22:00 UTC."
  project_id  = octopusdeploy_project.cart_inventory.id
  timezone    = "UTC"
  once_daily_schedule {
    start_time   = "2026-01-01T22:00:00"
    days_of_week = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
  }
  deploy_latest_release_action {
    source_environment_id      = local.env.dev
    destination_environment_id = local.env.test
    should_redeploy            = false
  }
}

# --- Order Processing (fast-track lifecycle) --------------------------------
resource "octopusdeploy_project" "cart_orders" {
  name             = "Cartwheel - Order Processing"
  slug             = "cartwheel-order-processing"
  description      = "Fast-track lifecycle: Dev OR Test is enough to promote to Prod."
  project_group_id = octopusdeploy_project_group.retail.id
  lifecycle_id     = octopusdeploy_lifecycle.nonprod_fast.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_process" "cart_orders" {
  project_id = octopusdeploy_project.cart_orders.id
}
resource "octopusdeploy_process_step" "cart_orders" {
  process_id     = octopusdeploy_process.cart_orders.id
  name           = "Deploy order processor"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/deploy-app.sh") })
}
