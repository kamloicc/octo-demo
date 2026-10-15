# =============================================================================
# FINANCIAL SERVICES - FinTrust Bank
# Features: regulated lifecycle, change tickets (ITSM), manual intervention
# with responsible team, separation of duties, rolling deployment with child
# steps, hotfix channel, sensitive + prompted variables, DB migrations with
# artifacts, DBA review, runbooks (backup / PITR restore), scheduled triggers,
# deployment freezes (see governance.tf), audit trail.
# =============================================================================

# --- Payments API ------------------------------------------------------------
resource "octopusdeploy_project" "fin_payments" {
  name                           = "FinTrust - Payments API"
  slug                           = "fintrust-payments-api"
  description                    = "Card payments API. PCI-DSS scope. Rolling deploy across 3 prod nodes."
  project_group_id               = octopusdeploy_project_group.finance.id
  lifecycle_id                   = octopusdeploy_lifecycle.regulated.id
  project_tags                   = [octopusdeploy_tag.compliance["pci"].canonical_tag_name, octopusdeploy_tag.compliance["sox"].canonical_tag_name]
  included_library_variable_sets = [octopusdeploy_library_variable_set.notifications.id, octopusdeploy_library_variable_set.observability.id, octopusdeploy_library_variable_set.demo_controls.id]
  default_guided_failure_mode    = "On"
  release_notes_template         = "Payments API #{Octopus.Release.Number}\n\nWork items:\n#{each workItem in Octopus.Release.WorkItems}- [#{workItem.Id}](#{workItem.LinkUrl}) #{workItem.Description}\n#{/each}"
  connectivity_policy {
    allow_deployments_to_no_targets = false
    skip_machine_behavior           = "None"
  }
}

resource "octopusdeploy_channel" "fin_payments_hotfix" {
  name         = "Hotfix"
  description  = "Emergency fixes: Staging > Production only."
  project_id   = octopusdeploy_project.fin_payments.id
  lifecycle_id = octopusdeploy_lifecycle.hotfix.id
}

resource "octopusdeploy_project_versioning_strategy" "fin_payments" {
  project_id = octopusdeploy_project.fin_payments.id
  space_id   = var.space_id
  template   = "#{Octopus.Date.Year}.#{Octopus.Date.Month}.#{Octopus.Version.NextPatch}"
}

# Variables
resource "octopusdeploy_variable" "fin_pay_url" {
  for_each = { dev = "dev", test = "test", staging = "staging", prod = "www", dr = "dr" }
  owner_id = octopusdeploy_project.fin_payments.id
  name     = "App.Url"
  type     = "String"
  value    = "https://payments.${each.value}.fintrust.example"
  scope { environments = [local.env[each.key]] }
}
resource "octopusdeploy_variable" "fin_pay_db_pwd" {
  for_each        = { nonprod = [local.env.dev, local.env.test, local.env.staging], prod = [local.env.prod, local.env.dr] }
  owner_id        = octopusdeploy_project.fin_payments.id
  name            = "Database.Password"
  type            = "Sensitive"
  is_sensitive    = true
  sensitive_value = "demo-${each.key}-P@ssw0rd!"
  scope { environments = each.value }
}
resource "octopusdeploy_variable" "fin_pay_gateway_key" {
  owner_id        = octopusdeploy_project.fin_payments.id
  name            = "Payments.Gateway.ApiKey"
  type            = "Sensitive"
  is_sensitive    = true
  sensitive_value = "sk_live_demo_0000000000"
  scope { environments = [local.env.prod] }
}
resource "octopusdeploy_variable" "fin_pay_change" {
  owner_id = octopusdeploy_project.fin_payments.id
  name     = "Change.Ticket"
  type     = "String"
  value    = ""
  prompt {
    label       = "Change ticket (leave blank to raise one)"
    description = "ServiceNow / JSM change request number"
    is_required = false
    display_settings { control_type = "SingleLineText" }
  }
  scope { environments = [local.env.prod, local.env.dr] }
}

resource "octopusdeploy_process" "fin_payments" {
  project_id = octopusdeploy_project.fin_payments.id
}
resource "octopusdeploy_process_step" "fin_pay_change" {
  process_id     = octopusdeploy_process.fin_payments.id
  name           = "Raise or validate change request"
  slug           = "raise-change"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  environments   = [local.env.prod, local.env.dr]
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/change-ticket.sh") })
}
resource "octopusdeploy_process_step" "fin_pay_approval" {
  process_id   = octopusdeploy_process.fin_payments.id
  name         = "Release manager approval"
  type         = "Octopus.Manual"
  environments = [local.env.prod, local.env.dr]
  execution_properties = {
    "Octopus.Action.RunOnServer"                       = "true"
    "Octopus.Action.Manual.Instructions"               = "Approve Payments API #{Octopus.Release.Number} for #{Octopus.Environment.Name} under change #{Octopus.Action[Raise or validate change request].Output.ChangeTicket}. Review the release notes and the Staging smoke-test results."
    "Octopus.Action.Manual.BlockConcurrentDeployments" = "True"
    "Octopus.Action.Manual.ResponsibleTeamIds"         = octopusdeploy_team.fin_release_mgrs.id
  }
}

# Rolling deployment: parent step targets the role, one node at a time,
# child steps run sequentially per node.
resource "octopusdeploy_process_step" "fin_pay_rolling" {
  process_id     = octopusdeploy_process.fin_payments.id
  name           = "Rolling deploy - drain node"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  properties = {
    "Octopus.Action.TargetRoles"    = "fintrust-payments-api"
    "Octopus.Action.MaxParallelism" = "1"
  }
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      write_highlight "Draining #{Octopus.Machine.Name} from load balancer pool"
      sleep 2; echo "Active connections: 0"
    EOT
  })
}
resource "octopusdeploy_process_child_step" "fin_pay_deploy" {
  process_id     = octopusdeploy_process.fin_payments.id
  parent_id      = octopusdeploy_process_step.fin_pay_rolling.id
  name           = "Deploy Payments API"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/deploy-app.sh") })
}
resource "octopusdeploy_process_child_step" "fin_pay_readd" {
  process_id     = octopusdeploy_process.fin_payments.id
  parent_id      = octopusdeploy_process_step.fin_pay_rolling.id
  name           = "Health check and return node to pool"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      echo "GET http://#{Octopus.Machine.Name}:8080/healthz -> 200"
      write_highlight "#{Octopus.Machine.Name} back in pool"
    EOT
  })
}
resource "octopusdeploy_process_child_steps_order" "fin_pay_rolling" {
  process_id = octopusdeploy_process.fin_payments.id
  parent_id  = octopusdeploy_process_step.fin_pay_rolling.id
  children   = [octopusdeploy_process_child_step.fin_pay_deploy.id, octopusdeploy_process_child_step.fin_pay_readd.id]
}

resource "octopusdeploy_process_templated_step" "fin_pay_smoke" {
  process_id           = octopusdeploy_process.fin_payments.id
  name                 = "Smoke test"
  template_id          = octopusdeploy_step_template.smoke.id
  template_version     = octopusdeploy_step_template.smoke.version
  worker_pool_id       = local.wp_linux
  execution_properties = { "Octopus.Action.RunOnServer" = "true" }
  parameters           = { "Smoke.Url" = "#{App.Url}" }
}
resource "octopusdeploy_process_templated_step" "fin_pay_notify" {
  process_id           = octopusdeploy_process.fin_payments.id
  name                 = "Notify"
  template_id          = octopusdeploy_step_template.notify.id
  template_version     = octopusdeploy_step_template.notify.version
  worker_pool_id       = local.wp_linux
  condition            = "Always"
  execution_properties = { "Octopus.Action.RunOnServer" = "true" }
  parameters           = { "Notify.Template.Channel" = "#{Notify.Channel}" }
}
resource "octopusdeploy_process_steps_order" "fin_payments" {
  process_id = octopusdeploy_process.fin_payments.id
  steps = [
    octopusdeploy_process_step.fin_pay_change.id,
    octopusdeploy_process_step.fin_pay_approval.id,
    octopusdeploy_process_step.fin_pay_rolling.id,
    octopusdeploy_process_templated_step.fin_pay_smoke.id,
    octopusdeploy_process_templated_step.fin_pay_notify.id,
  ]
}

# --- Core Banking Database ---------------------------------------------------
resource "octopusdeploy_project" "fin_coredb" {
  name                           = "FinTrust - Core Banking Database"
  slug                           = "fintrust-core-banking-db"
  description                    = "Schema migrations with SQL preview artifact and DBA review. Backup / restore runbooks."
  project_group_id               = octopusdeploy_project_group.finance.id
  lifecycle_id                   = octopusdeploy_lifecycle.regulated.id
  project_tags                   = [octopusdeploy_tag.compliance["sox"].canonical_tag_name]
  included_library_variable_sets = [octopusdeploy_library_variable_set.notifications.id, octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_variable" "fin_db_name" {
  owner_id = octopusdeploy_project.fin_coredb.id
  name     = "Database.Name"
  type     = "String"
  value    = "corebanking_#{Octopus.Environment.Name | ToLower}"
}
resource "octopusdeploy_variable" "fin_db_pwd" {
  owner_id        = octopusdeploy_project.fin_coredb.id
  name            = "Database.Password"
  type            = "Sensitive"
  is_sensitive    = true
  sensitive_value = "demo-dba-secret"
}

resource "octopusdeploy_process" "fin_coredb" {
  project_id = octopusdeploy_project.fin_coredb.id
}
resource "octopusdeploy_process_step" "fin_db_preview" {
  process_id     = octopusdeploy_process.fin_coredb.id
  name           = "Generate migration preview"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      printf -- "-- DRY RUN for #{Database.Name}\nALTER TABLE customers ADD risk_score INT NULL;\nCREATE INDEX ix_tx_date ON transactions(tx_date);\nCREATE TABLE audit_trail (...);\n" > preview.sql
      new_octopusartifact "$(pwd)/preview.sql" "migration-preview-#{Octopus.Environment.Name}.sql"
      write_highlight "Preview generated - review the artifact before approving"
    EOT
  })
}
resource "octopusdeploy_process_step" "fin_db_review" {
  process_id   = octopusdeploy_process.fin_coredb.id
  name         = "DBA review of migration script"
  type         = "Octopus.Manual"
  environments = [local.env.staging, local.env.prod]
  execution_properties = {
    "Octopus.Action.RunOnServer"                       = "true"
    "Octopus.Action.Manual.Instructions"               = "Download the migration-preview artifact and confirm no destructive changes."
    "Octopus.Action.Manual.BlockConcurrentDeployments" = "True"
    "Octopus.Action.Manual.ResponsibleTeamIds"         = octopusdeploy_team.fin_release_mgrs.id
  }
}
resource "octopusdeploy_process_step" "fin_db_migrate" {
  process_id     = octopusdeploy_process.fin_coredb.id
  name           = "Apply migrations"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  properties     = { "Octopus.Action.TargetRoles" = "fintrust-core-db" }
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/db-migrate.sh") })
}
resource "octopusdeploy_process_steps_order" "fin_coredb" {
  process_id = octopusdeploy_process.fin_coredb.id
  steps      = [octopusdeploy_process_step.fin_db_preview.id, octopusdeploy_process_step.fin_db_review.id, octopusdeploy_process_step.fin_db_migrate.id]
}

# Runbooks
resource "octopusdeploy_runbook" "fin_db_backup" {
  project_id        = octopusdeploy_project.fin_coredb.id
  name              = "Backup Database"
  description       = "Nightly full backup. Scheduled via trigger (enable_scheduled_triggers)."
  environment_scope = "All"
  runbook_tags      = [octopusdeploy_tag.runbook_type["maint"].canonical_tag_name]
  retention_policy_with_strategy {
    strategy         = "Count"
    quantity_to_keep = 14
    unit             = "Items"
  }
}
resource "octopusdeploy_process" "fin_db_backup" {
  project_id = octopusdeploy_project.fin_coredb.id
  runbook_id = octopusdeploy_runbook.fin_db_backup.id
}
resource "octopusdeploy_process_step" "fin_db_backup" {
  process_id     = octopusdeploy_process.fin_db_backup.id
  name           = "Full backup to object storage"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      FILE="#{Database.Name}_$(date -u +%Y%m%dT%H%M%SZ).bak"
      echo "BACKUP DATABASE #{Database.Name} TO URL='s3://fintrust-backups/$FILE'"; sleep 3
      write_highlight "Backup complete: $FILE (4.2 GB, checksum verified)"
    EOT
  })
}

resource "octopusdeploy_runbook" "fin_db_restore" {
  project_id        = octopusdeploy_project.fin_coredb.id
  name              = "Point-in-time Restore"
  description       = "DR runbook with prompted restore point and approval."
  environment_scope = "Specified"
  environments      = [local.env.staging, local.env.prod, local.env.dr]
  runbook_tags      = [octopusdeploy_tag.runbook_type["dr"].canonical_tag_name]
}
resource "octopusdeploy_variable" "fin_restore_point" {
  owner_id = octopusdeploy_project.fin_coredb.id
  name     = "Restore.PointInTime"
  type     = "String"
  value    = ""
  prompt {
    label       = "Restore point (UTC, e.g. 2026-10-15T02:00:00Z)"
    is_required = true
    display_settings { control_type = "SingleLineText" }
  }
  scope { processes = [octopusdeploy_runbook.fin_db_restore.id] }
}
resource "octopusdeploy_process" "fin_db_restore" {
  project_id = octopusdeploy_project.fin_coredb.id
  runbook_id = octopusdeploy_runbook.fin_db_restore.id
}
resource "octopusdeploy_process_step" "fin_db_restore_approve" {
  process_id = octopusdeploy_process.fin_db_restore.id
  name       = "Approve restore"
  type       = "Octopus.Manual"
  execution_properties = {
    "Octopus.Action.RunOnServer"               = "true"
    "Octopus.Action.Manual.Instructions"       = "Restore #{Database.Name} to #{Restore.PointInTime}? This overwrites current data."
    "Octopus.Action.Manual.ResponsibleTeamIds" = octopusdeploy_team.fin_release_mgrs.id
  }
}
resource "octopusdeploy_process_step" "fin_db_restore_run" {
  process_id     = octopusdeploy_process.fin_db_restore.id
  name           = "Restore database"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      echo "RESTORE DATABASE #{Database.Name} WITH STOPAT = '#{Restore.PointInTime}'"; sleep 3
      write_highlight "Restored #{Database.Name} to #{Restore.PointInTime}"
    EOT
  })
}
resource "octopusdeploy_process_steps_order" "fin_db_restore" {
  process_id = octopusdeploy_process.fin_db_restore.id
  steps      = [octopusdeploy_process_step.fin_db_restore_approve.id, octopusdeploy_process_step.fin_db_restore_run.id]
}

resource "octopusdeploy_project_scheduled_trigger" "fin_db_nightly_backup" {
  count       = var.enable_scheduled_triggers ? 1 : 0
  space_id    = var.space_id
  name        = "Nightly production backup"
  description = "Runs the published 'Backup Database' runbook at 02:00 UTC."
  project_id  = octopusdeploy_project.fin_coredb.id
  timezone    = "UTC"
  cron_expression_schedule {
    cron_expression = "0 0 2 * * *"
  }
  run_runbook_action {
    runbook_id             = octopusdeploy_runbook.fin_db_backup.id
    target_environment_ids = [local.env.prod]
  }
}

# --- Fraud Scoring Model -----------------------------------------------------
resource "octopusdeploy_project" "fin_fraud" {
  name                           = "FinTrust - Fraud Scoring Model"
  slug                           = "fintrust-fraud-scoring-model"
  description                    = "ML model release with shadow evaluation before promotion."
  project_group_id               = octopusdeploy_project_group.finance.id
  lifecycle_id                   = octopusdeploy_lifecycle.standard.id
  included_library_variable_sets = [octopusdeploy_library_variable_set.observability.id, octopusdeploy_library_variable_set.demo_controls.id]
  connectivity_policy {
    allow_deployments_to_no_targets = true
  }
}
resource "octopusdeploy_process" "fin_fraud" {
  project_id = octopusdeploy_project.fin_fraud.id
}
resource "octopusdeploy_process_step" "fin_fraud_deploy" {
  process_id     = octopusdeploy_process.fin_fraud.id
  name           = "Deploy model to shadow endpoint"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = <<-EOT
      if [ "#{Demo.FailDeployment | Default False}" = "True" ]; then fail_step "Simulated failure (Demo.FailDeployment)"; fi
      echo "Registering model fraud-xgb:#{Octopus.Release.Number} in model registry"
      echo "Routing 10% mirrored traffic to shadow endpoint"; sleep 2
      write_highlight "Shadow model live"
    EOT
  })
}
resource "octopusdeploy_process_step" "fin_fraud_eval" {
  process_id     = octopusdeploy_process.fin_fraud.id
  name           = "Evaluate shadow vs champion"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, { "Octopus.Action.Script.ScriptBody" = file("${local.scripts}/canary-analysis.sh") })
}
resource "octopusdeploy_process_step" "fin_fraud_promote" {
  process_id     = octopusdeploy_process.fin_fraud.id
  name           = "Promote model to champion"
  type           = "Octopus.Script"
  worker_pool_id = local.wp_linux
  execution_properties = merge(local.bash, {
    "Octopus.Action.Script.ScriptBody" = "write_highlight \"fraud-xgb:#{Octopus.Release.Number} is now champion in #{Octopus.Environment.Name}\""
  })
}
resource "octopusdeploy_process_steps_order" "fin_fraud" {
  process_id = octopusdeploy_process.fin_fraud.id
  steps      = [octopusdeploy_process_step.fin_fraud_deploy.id, octopusdeploy_process_step.fin_fraud_eval.id, octopusdeploy_process_step.fin_fraud_promote.id]
}
