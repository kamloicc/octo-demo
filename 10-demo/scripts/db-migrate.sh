#!/bin/bash
# Simulated database migration (Flyway / Liquibase / DbUp style).
DB="#{Database.Name | Default 'appdb'}"
echo "Connecting to #{Database.Server | Default 'db.internal'} / $DB as #{Database.User | Default 'svc_deploy'}"
echo "Password is sensitive and masked in logs: #{Database.Password | Default 'not-set'}"
cat > migration-report.sql <<SQL
-- Migration report for $DB, release #{Octopus.Release.Number}
-- V2026.10.1__add_customer_risk_score.sql   APPLIED
-- V2026.10.2__index_transactions_by_date.sql APPLIED
-- V2026.10.3__create_audit_trail_table.sql  APPLIED
SQL
if [ "#{Demo.FailDeployment | Default False}" = "True" ]; then
  echo "  -> Starting new version... ERROR: health probe timed out after 30s (exit 137, OOMKilled)"
  fail_step "Deployment of #{Octopus.Project.Name} #{Octopus.Release.Number} failed on #{Octopus.Machine.Name | Default 'worker'}: container OOMKilled"
fi
cat migration-report.sql
new_octopusartifact "$(pwd)/migration-report.sql" "migration-report-#{Octopus.Environment.Name}.sql"
write_highlight "3 migrations applied to $DB"
