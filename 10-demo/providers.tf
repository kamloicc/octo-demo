terraform {
  required_version = ">= 1.5.0"
  required_providers {
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "~> 1.20"
    }
  }
}

provider "octopusdeploy" {
  address  = var.octopus_url
  api_key  = var.octopus_api_key
  space_id = var.space_id
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------
variable "octopus_url" {
  type = string
}

variable "octopus_api_key" {
  type      = string
  sensitive = true
}

variable "space_id" {
  type        = string
  description = "Output of stage 00 (Spaces-xxx)."
}

variable "docker_hub_username" {
  type        = string
  default     = ""
  description = "Optional. Avoids Docker Hub anonymous rate limits for the external feed trigger."
}

variable "docker_hub_token" {
  type      = string
  default   = ""
  sensitive = true
}

variable "demo_user_ids" {
  type        = list(string)
  default     = []
  description = "Users added to every demo team (so they can take manual interventions). deploy.sh sets this to the API key user."
}

variable "enable_release_train" {
  type        = bool
  default     = true
  description = "Creates the 'Deploy a Release' orchestration project. Set false if your instance rejects the step."
}

variable "enable_scheduled_triggers" {
  type        = bool
  default     = false
  description = "Scheduled triggers need published runbooks / existing releases. Turn on after first demo run."
}

# Shared helpers -------------------------------------------------------------
locals {
  wp_linux   = octopusdeploy_dynamic_worker_pool.ubuntu.id
  wp_windows = octopusdeploy_dynamic_worker_pool.windows.id

  env = {
    dev     = octopusdeploy_environment.development.id
    test    = octopusdeploy_environment.test.id
    staging = octopusdeploy_environment.staging.id
    prod    = octopusdeploy_environment.production.id
    dr      = octopusdeploy_environment.dr.id
  }

  # Execution properties for an inline Bash script on a worker
  bash = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "Bash"
  }
  pwsh = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
  }

  # Standard connectivity: allow deploying when no targets match (simulated infra)
  scripts = "${path.module}/scripts"
}
