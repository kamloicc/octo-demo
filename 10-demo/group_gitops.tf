# =============================================================================
# KUBERNETES & GITOPS - Argo CD
# Octopus adds environment promotion, approvals, RBAC, audit and verification
# on top of Argo CD's continuous sync.
#
# Today (no infra): projects, variables, image references and placeholder steps
# work end-to-end. When an Argo CD instance + Octopus gateway is connected:
#   1. Apply ../gitops/argocd-apps/*.yaml to the cluster (annotations already
#      match the project/environment slugs below).
#   2. In each project, disable the "- simulated" step and add the native
#      "Update Argo CD Application Image Tags" / "Update Argo CD Application
#      Manifests" step (see README, section Phase 2).
# =============================================================================

resource "octopusdeploy_project" "argo_image" {
  name                           = "Argo CD - Podinfo (Image Tags)"
  slug                           = "argo-podinfo-image-tags"
  description                    = "Octopus promotes a container image tag through environments; Argo CD syncs. Annotations: argo.octopus.com/project=argo-podinfo-image-tags"
  project_group_id               = octopusdeploy_project_group.gitops.id
  lifecycle_id                   = octopusdeploy_lifecycle.standard.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.notifications.id, octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_process" "argo_image" {
  project_id = octopusdeploy_project.argo_image.id
}
resource "octopusdeploy_process_step" "argo_image_approve" {
  process_id   = octopusdeploy_process.argo_image.id
  name         = "Production approval"
  type         = "Octopus.Manual"
  environments = [local.env.prod]
  execution_properties = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Manual.Instructions" = "Approve promoting podinfo #{Octopus.Action.Package[podinfo].PackageVersion} to Production via Argo CD."
  }
}
resource "octopusdeploy_process_step" "argo_image_update" {
  process_id     = octopusdeploy_process.argo_image.id
  name           = "Update Argo CD image tag - simulated"
  slug           = "update-argo-image-tag"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  packages = {
    "podinfo" = merge(local.podinfo_pkg, { package_id = "stefanprodan/podinfo" })
  }
  notes                = "Replace with the native 'Update Argo CD Application Image Tags' step once the Argo CD gateway is installed."
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/argo-placeholder.sh") })
}
resource "octopusdeploy_process_templated_step" "argo_image_notify" {
  process_id           = octopusdeploy_process.argo_image.id
  name                 = "Notify"
  template_id          = octopusdeploy_step_template.notify.id
  template_version     = octopusdeploy_step_template.notify.version
  worker_pool_id       = local.wp_linux
  execution_properties = { "Octopus.Action.RunOnServer" = "true" }
  parameters           = { "Notify.Template.Channel" = "#gitops" }
}
resource "octopusdeploy_process_steps_order" "argo_image" {
  process_id = octopusdeploy_process.argo_image.id
  steps      = [octopusdeploy_process_step.argo_image_approve.id, octopusdeploy_process_step.argo_image_update.id, octopusdeploy_process_templated_step.argo_image_notify.id]
}

# --- Manifests (templated with Octopus variables) ---------------------------
resource "octopusdeploy_project" "argo_manifests" {
  name             = "Argo CD - Podinfo (Manifests)"
  slug             = "argo-podinfo-manifests"
  description      = "Octopus renders manifests from templates + environment-scoped variables and commits them for Argo CD."
  project_group_id = octopusdeploy_project_group.gitops.id
  lifecycle_id     = octopusdeploy_lifecycle.standard.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_variable" "argo_replicas" {
  for_each = { dev = "1", test = "1", staging = "2", prod = "3" }
  owner_id = octopusdeploy_project.argo_manifests.id
  name     = "Podinfo.Replicas"
  type     = "String"
  value    = each.value
  scope { environments = [local.env[each.key]] }
}
resource "octopusdeploy_variable" "argo_message" {
  owner_id = octopusdeploy_project.argo_manifests.id
  name     = "Podinfo.Message"
  type     = "String"
  value    = "Deployed by Octopus to #{Octopus.Environment.Name} - release #{Octopus.Release.Number}"
}
resource "octopusdeploy_variable" "argo_color" {
  for_each = { dev = "#34577c", test = "#2E7D32", staging = "#EF6C00", prod = "#C62828" }
  owner_id = octopusdeploy_project.argo_manifests.id
  name     = "Podinfo.Color"
  type     = "String"
  value    = each.value
  scope { environments = [local.env[each.key]] }
}
resource "octopusdeploy_process" "argo_manifests" {
  project_id = octopusdeploy_project.argo_manifests.id
}
resource "octopusdeploy_process_step" "argo_manifests_update" {
  process_id     = octopusdeploy_process.argo_manifests.id
  name           = "Update Argo CD manifests - simulated"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  notes          = "Replace with the native 'Update Argo CD Application Manifests' step. Templates live in gitops/templates/."
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      write_warning "Simulated - no Argo CD instance connected"
      if [ "#{Demo.FailDeployment | Default False}" = "True" ]; then fail_step "Simulated failure (Demo.FailDeployment)"; fi
      echo "Rendering gitops/templates/deployment.yaml with:"
      echo "  replicas = #{Podinfo.Replicas}"
      echo "  PODINFO_UI_MESSAGE = #{Podinfo.Message}"
      echo "  PODINFO_UI_COLOR   = #{Podinfo.Color}"
      echo "git commit -m 'Octopus: render manifests for #{Octopus.Environment.Slug}'"
    EOT
  })
}

# --- Kubernetes (Helm via Kubernetes agent) - phase 2 ------------------------
resource "octopusdeploy_project" "k8s_helm" {
  name             = "Kubernetes - Podinfo Helm (K8s Agent)"
  slug             = "k8s-podinfo-helm"
  description      = "Phase 2: install the Octopus Kubernetes agent (target tag 'k8s-podinfo') and replace the placeholder with the 'Deploy a Helm Chart' step using the 'Helm - podinfo' feed."
  project_group_id = octopusdeploy_project_group.gitops.id
  lifecycle_id     = octopusdeploy_lifecycle.standard.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_process" "k8s_helm" {
  project_id = octopusdeploy_project.k8s_helm.id
}
resource "octopusdeploy_process_step" "k8s_helm" {
  process_id     = octopusdeploy_process.k8s_helm.id
  name           = "Helm upgrade podinfo - simulated"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = "if [ \"#{Demo.FailDeployment | Default False}\" = \"True\" ]; then fail_step 'Simulated failure'; fi; write_warning 'Simulated'; echo 'helm upgrade --install podinfo podinfo/podinfo -n podinfo-#{Octopus.Environment.Slug} --set replicaCount=2'"
  })
}
