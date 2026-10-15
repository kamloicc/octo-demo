# =============================================================================
# PUBLIC SECTOR - CivicOne
# Features: security gate with SBOM + scan artifacts, two sequential approvals
# by different teams (CAB then Security), required steps that cannot be
# skipped, air-gapped bundle export, compliance evidence pack runbook.
# =============================================================================

resource "octopusdeploy_project" "civic_portal" {
  name                           = "CivicOne - Citizen Services Portal"
  slug                           = "civicone-citizen-services-portal"
  description                    = "Benefits / permits portal. FedRAMP-style controls: security gate, dual approval, evidence."
  project_group_id               = octopusdeploy_project_group.public_sector.id
  lifecycle_id                   = octopusdeploy_lifecycle.regulated.id
  project_tags                   = [octopusdeploy_tag.compliance["fedramp"].canonical_tag_name, octopusdeploy_tag.compliance["iso"].canonical_tag_name]
  included_library_variable_sets = [octopusdeploy_library_variable_set.notifications.id, octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_variable" "civic_url" {
  owner_id = octopusdeploy_project.civic_portal.id
  name     = "App.Url"
  type     = "String"
  value    = "https://#{Octopus.Environment.Name | ToLower}.services.civicone.example"
}

resource "octopusdeploy_process" "civic_portal" {
  project_id = octopusdeploy_project.civic_portal.id
}
resource "octopusdeploy_process_step" "civic_scan" {
  process_id     = octopusdeploy_process.civic_portal.id
  name           = "Security scan and SBOM"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  is_required    = true # cannot be skipped at deploy time
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/security-scan.sh") })
}
resource "octopusdeploy_process_step" "civic_cab" {
  process_id   = octopusdeploy_process.civic_portal.id
  name         = "CAB approval"
  type         = "Octopus.Manual"
  environments = [local.env.prod]
  is_required  = true
  execution_properties = {
    "Octopus.Action.RunOnServer"                       = "true"
    "Octopus.Action.Manual.Instructions"               = "CAB: confirm change window and rollback plan."
    "Octopus.Action.Manual.BlockConcurrentDeployments" = "True"
    "Octopus.Action.Manual.ResponsibleTeamIds"         = octopusdeploy_team.civic_cab.id
  }
}
resource "octopusdeploy_process_step" "civic_sec" {
  process_id   = octopusdeploy_process.civic_portal.id
  name         = "Security officer approval"
  type         = "Octopus.Manual"
  environments = [local.env.prod]
  is_required  = true
  execution_properties = {
    "Octopus.Action.RunOnServer"               = "true"
    "Octopus.Action.Manual.Instructions"       = "Security: review SBOM and scan-summary artifacts from step 1."
    "Octopus.Action.Manual.ResponsibleTeamIds" = octopusdeploy_team.civic_security.id
  }
}
resource "octopusdeploy_process_step" "civic_deploy" {
  process_id     = octopusdeploy_process.civic_portal.id
  name           = "Deploy portal"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  properties     = { "Octopus.Action.TargetRoles" = "civicone-portal" }
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/deploy-app.sh") })
}
resource "octopusdeploy_process_templated_step" "civic_smoke" {
  process_id           = octopusdeploy_process.civic_portal.id
  name                 = "Smoke test"
  template_id          = octopusdeploy_step_template.smoke.id
  template_version     = octopusdeploy_step_template.smoke.version
  worker_pool_id       = local.wp_linux
  execution_properties = { "Octopus.Action.RunOnServer" = "true" }
  parameters           = { "Smoke.Url" = "#{App.Url}" }
}
resource "octopusdeploy_process_steps_order" "civic_portal" {
  process_id = octopusdeploy_process.civic_portal.id
  steps = [
    octopusdeploy_process_step.civic_scan.id,
    octopusdeploy_process_step.civic_cab.id,
    octopusdeploy_process_step.civic_sec.id,
    octopusdeploy_process_step.civic_deploy.id,
    octopusdeploy_process_templated_step.civic_smoke.id,
  ]
}

resource "octopusdeploy_runbook" "civic_evidence" {
  project_id        = octopusdeploy_project.civic_portal.id
  name              = "Generate Compliance Evidence Pack"
  description       = "Bundles deployment history, approvals and SBOMs for auditors."
  environment_scope = "Specified"
  environments      = [local.env.prod]
  runbook_tags      = [octopusdeploy_tag.runbook_type["maint"].canonical_tag_name]
}
resource "octopusdeploy_process" "civic_evidence" {
  project_id = octopusdeploy_project.civic_portal.id
  runbook_id = octopusdeploy_runbook.civic_evidence.id
}
resource "octopusdeploy_process_step" "civic_evidence" {
  process_id     = octopusdeploy_process.civic_evidence.id
  name           = "Build evidence pack"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      mkdir -p evidence && cd evidence
      echo "Pulling audit events, approvals and artifacts via Octopus REST API (simulated)"
      printf "control,evidence,status\nCM-3,Change approvals (CAB + Security),PASS\nRA-5,Vulnerability scan per release,PASS\nSA-11,SBOM per release,PASS\nAU-6,Audit log export,PASS\n" > controls.csv
      cd .. && tar czf evidence-pack.tgz evidence
      new_octopusartifact "$(pwd)/evidence-pack.tgz" "evidence-pack-$(date -u +%Y%m%d).tgz"
      write_highlight "Evidence pack ready for auditors"
    EOT
  })
}

# --- Records Archive (air-gapped) -------------------------------------------
resource "octopusdeploy_project" "civic_records" {
  name             = "CivicOne - Records Archive (Air-gapped)"
  slug             = "civicone-records-archive"
  description      = "Classified network with no inbound connectivity. Octopus produces a signed offline bundle (Offline Package Drop pattern)."
  project_group_id = octopusdeploy_project_group.public_sector.id
  lifecycle_id     = octopusdeploy_lifecycle.regulated.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.demo_controls.id]
  project_tags     = [octopusdeploy_tag.compliance["fedramp"].canonical_tag_name]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_process" "civic_records" {
  project_id = octopusdeploy_project.civic_records.id
}
resource "octopusdeploy_process_step" "civic_records_bundle" {
  process_id     = octopusdeploy_process.civic_records.id
  name           = "Build signed offline bundle"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_windows
  execution_properties = merge(local.pwsh, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      if ("#{Demo.FailDeployment | Default False}" -eq "True") { Fail-Step "Simulated failure (Demo.FailDeployment)" }
      New-Item -ItemType Directory -Force -Path bundle | Out-Null
      "Release #{Octopus.Release.Number} for #{Octopus.Environment.Name}" | Out-File bundle\README.txt
      "Install-RecordsArchive -Version #{Octopus.Release.Number}" | Out-File bundle\Install.ps1
      Compress-Archive -Path bundle\* -DestinationPath records-#{Octopus.Release.Number}.zip -Force
      $hash = (Get-FileHash records-#{Octopus.Release.Number}.zip -Algorithm SHA256).Hash
      $hash | Out-File records-#{Octopus.Release.Number}.sha256
      New-OctopusArtifact "records-#{Octopus.Release.Number}.zip"
      New-OctopusArtifact "records-#{Octopus.Release.Number}.sha256"
      Write-Highlight "Offline bundle ready (SHA256 $hash). Transfer via approved media."
    EOT
  })
}
