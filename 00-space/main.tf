# -----------------------------------------------------------------------------
# Stage 00 - Create the demo space.
# The provider must be scoped to a space for stage 10, so the space is created
# in its own small stage first. Output "space_id" feeds stage 10.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "~> 1.20"
    }
  }
}

variable "octopus_url" {
  type        = string
  description = "e.g. https://your-instance.octopus.app"
}

variable "octopus_api_key" {
  type      = string
  sensitive = true
}

variable "space_name" {
  type    = string
  default = "SE Industry Demos"
}

variable "is_task_queue_stopped" {
  type        = bool
  default     = false
  description = "Set true (destroy.sh does this) before deleting the space."
}

variable "space_manager_user_ids" {
  type        = list(string)
  default     = []
  description = "Optional user IDs (Users-123) to make Space Managers."
}

provider "octopusdeploy" {
  address = var.octopus_url
  api_key = var.octopus_api_key
}

resource "octopusdeploy_space" "demo" {
  name                        = var.space_name
  slug                        = "se-industry-demos"
  description                 = "Solution Engineering demo space: one project group per industry plus Platform Engineering and GitOps (Argo CD). Managed by Terraform - re-apply to reset."
  is_default                  = false
  is_task_queue_stopped       = var.is_task_queue_stopped
  space_managers_team_members = var.space_manager_user_ids
  space_managers_teams        = ["teams-administrators", "teams-managers"]
}

output "space_id" {
  value = octopusdeploy_space.demo.id
}
