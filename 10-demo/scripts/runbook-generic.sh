#!/bin/bash
# Generic simulated operations task used by many runbooks.
echo "Runbook   : #{Octopus.Runbook.Name}"
echo "Project   : #{Octopus.Project.Name}"
echo "Env       : #{Octopus.Environment.Name}"
echo "Tenant    : #{Octopus.Deployment.Tenant.Name | Default 'n/a'}"
echo "Requested : #{Octopus.Deployment.CreatedBy.DisplayName}"
echo "Reason    : #{Runbook.Reason | Default 'not specified'}"
for s in #{Runbook.Steps | Default 'Preparing Executing Verifying'}; do echo "  -> $s"; sleep 1; done
write_highlight "#{Octopus.Runbook.Name} completed in #{Octopus.Environment.Name}"
