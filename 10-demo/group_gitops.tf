# =============================================================================
# KUBERNETES & GITOPS - real infrastructure
#
# Kubernetes agent (target tag var.k8s_target_tag):
#   "Kubernetes - Podinfo Helm (K8s Agent)" is fully managed here: Helm upgrade
#   with environment-specific values, Kubernetes object status check, kubectl
#   verification. Demo.FailDeployment pushes a non-existent image tag so the
#   rollout really fails (ImagePullBackOff) - great for failure analysis.
#
# Argo CD (gateway installed):
#   The native Argo CD step types are not documented for the Terraform
#   provider, so Terraform manages the projects, variables and the approval
#   step, and you add the native step once in the UI (see README > Argo CD).
#   Steps added in the UI are kept by Terraform (appended after managed steps).
# =============================================================================

variable "k8s_target_tag" {
  type        = string
  default     = "k8s-podinfo"
  description = "Target tag (role) given to the Kubernetes agent."
}

locals {
  podinfo_settings = {
    replicas = { dev = "1", test = "1", staging = "2", prod = "3" }
    color    = { dev = "#34577c", test = "#2E7D32", staging = "#EF6C00", prod = "#C62828" }
  }
  podinfo_projects = {
    manifests = octopusdeploy_project.argo_manifests.id
    helm      = octopusdeploy_project.k8s_helm.id
  }
  podinfo_replicas = { for p in setproduct(keys(local.podinfo_projects), keys(local.podinfo_settings.replicas)) : "${p[0]}-${p[1]}" => { project = p[0], env = p[1] } }
}

# --- Argo CD: image tags -----------------------------------------------------
resource "octopusdeploy_project" "argo_image" {
  name                           = "Argo CD - Podinfo (Image Tags)"
  slug                           = "argo-podinfo-image-tags"
  description                    = "Octopus promotes the podinfo image tag through environments; Argo CD syncs. Annotations: argo.octopus.com/project=argo-podinfo-image-tags"
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
    "Octopus.Action.Manual.Instructions" = "Approve promoting podinfo (release #{Octopus.Release.Number}) to Production via Argo CD."
  }
}
resource "octopusdeploy_process_steps_order" "argo_image" {
  process_id = octopusdeploy_process.argo_image.id
  steps      = [octopusdeploy_process_step.argo_image_approve.id]
}

# --- Argo CD: manifests ------------------------------------------------------
resource "octopusdeploy_project" "argo_manifests" {
  name                           = "Argo CD - Podinfo (Manifests)"
  slug                           = "argo-podinfo-manifests"
  description                    = "Octopus renders gitops/templates/ with environment-scoped variables and commits them for Argo CD."
  project_group_id               = octopusdeploy_project_group.gitops.id
  lifecycle_id                   = octopusdeploy_lifecycle.standard.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_process" "argo_manifests" {
  project_id = octopusdeploy_project.argo_manifests.id
}
resource "octopusdeploy_process_step" "argo_manifests_approve" {
  process_id   = octopusdeploy_process.argo_manifests.id
  name         = "Production approval"
  type         = "Octopus.Manual"
  environments = [local.env.prod]
  execution_properties = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Manual.Instructions" = "Approve rendering podinfo manifests for Production (replicas #{Podinfo.Replicas})."
  }
}
resource "octopusdeploy_process_steps_order" "argo_manifests" {
  process_id = octopusdeploy_process.argo_manifests.id
  steps      = [octopusdeploy_process_step.argo_manifests_approve.id]
}

# Shared podinfo variables (used by the Argo manifests templates and Helm values)
resource "octopusdeploy_variable" "podinfo_replicas" {
  for_each = local.podinfo_replicas
  owner_id = local.podinfo_projects[each.value.project]
  name     = "Podinfo.Replicas"
  type     = "String"
  value    = local.podinfo_settings.replicas[each.value.env]
  scope { environments = [local.env[each.value.env]] }
}
resource "octopusdeploy_variable" "podinfo_color" {
  for_each = local.podinfo_replicas
  owner_id = local.podinfo_projects[each.value.project]
  name     = "Podinfo.Color"
  type     = "String"
  value    = local.podinfo_settings.color[each.value.env]
  scope { environments = [local.env[each.value.env]] }
}
resource "octopusdeploy_variable" "podinfo_message" {
  for_each = local.podinfo_projects
  owner_id = each.value
  name     = "Podinfo.Message"
  type     = "String"
  value    = "Deployed by Octopus to #{Octopus.Environment.Name} - release #{Octopus.Release.Number}"
}
resource "octopusdeploy_variable" "podinfo_namespace" {
  owner_id = octopusdeploy_project.k8s_helm.id
  name     = "Podinfo.Namespace"
  type     = "String"
  value    = "podinfo-helm-#{Octopus.Environment.Slug}"
}

# --- Kubernetes agent: Helm --------------------------------------------------
resource "octopusdeploy_project" "k8s_helm" {
  name                           = "Kubernetes - Podinfo Helm (K8s Agent)"
  slug                           = "k8s-podinfo-helm"
  description                    = "Helm chart deployed by the Octopus Kubernetes agent (target tag '${var.k8s_target_tag}'). Check Live Status after deploying."
  project_group_id               = octopusdeploy_project_group.gitops.id
  lifecycle_id                   = octopusdeploy_lifecycle.standard.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.demo_controls.id, octopusdeploy_library_variable_set.notifications.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true # environments without an agent are skipped
  }
}
resource "octopusdeploy_process" "k8s_helm" {
  project_id = octopusdeploy_project.k8s_helm.id
}
resource "octopusdeploy_process_step" "k8s_helm_approve" {
  process_id   = octopusdeploy_process.k8s_helm.id
  name         = "Production approval"
  type         = "Octopus.Manual"
  environments = [local.env.prod]
  execution_properties = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Manual.Instructions" = "Approve Helm upgrade of podinfo (release #{Octopus.Release.Number}) to Production."
  }
}
resource "octopusdeploy_process_step" "k8s_helm_deploy" {
  process_id = octopusdeploy_process.k8s_helm.id
  name       = "Deploy podinfo Helm chart"
  type       = "Octopus.HelmChartUpgrade"
  properties = { "Octopus.Action.TargetRoles" = var.k8s_target_tag }
  primary_package = {
    package_id           = "podinfo"
    feed_id              = octopusdeploy_helm_feed.podinfo.id
    acquisition_location = "Server"
    properties           = { "SelectionMode" = "immediate" }
  }
  execution_properties = {
    "Octopus.Action.RunOnServer"                   = "false"
    "Octopus.Action.Helm.ClientVersion"            = "V3"
    "Octopus.Action.Helm.ReleaseName"              = "podinfo"
    "Octopus.Action.Helm.Namespace"                = "#{Podinfo.Namespace}"
    "Octopus.Action.Helm.AdditionalArgs"           = "--create-namespace"
    "Octopus.Action.Helm.ResetValues"              = "True"
    "Octopus.Action.Kubernetes.ResourceStatusCheck" = "True"
    "Octopus.Action.Kubernetes.DeploymentTimeout"  = "120"
    "Octopus.Action.Helm.YamlValues"               = <<-EOT
      replicaCount: #{Podinfo.Replicas}
      ui:
        message: "#{Podinfo.Message}"
        color: "#{Podinfo.Color}"
      #{if Demo.FailDeployment == "True"}
      image:
        tag: 0.0.0-does-not-exist
      #{/if}
    EOT
  }
}
resource "octopusdeploy_process_step" "k8s_verify" {
  process_id = octopusdeploy_process.k8s_helm.id
  name       = "Verify rollout"
  type       = "Octopus.KubernetesRunScript"
  properties = { "Octopus.Action.TargetRoles" = var.k8s_target_tag }
  execution_properties = {
    "Octopus.Action.RunOnServer"         = "false"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "Bash"
    "Octopus.Action.Script.ScriptBody"   = <<-EOT
      NS="#{Podinfo.Namespace}"
      kubectl rollout status deployment/podinfo -n "$NS" --timeout=90s
      kubectl get deploy,pods,svc -n "$NS" -o wide
      write_highlight "podinfo release #{Octopus.Release.Number} running in $NS. Try: kubectl port-forward svc/podinfo 9898:9898 -n $NS"
    EOT
  }
}
resource "octopusdeploy_process_steps_order" "k8s_helm" {
  process_id = octopusdeploy_process.k8s_helm.id
  steps      = [octopusdeploy_process_step.k8s_helm_approve.id, octopusdeploy_process_step.k8s_helm_deploy.id, octopusdeploy_process_step.k8s_verify.id]
}
