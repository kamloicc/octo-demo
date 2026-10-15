#!/bin/bash
# Placeholder until an Argo CD instance + gateway is connected.
# Replace (or disable) this step and add the native step:
#   "Update Argo CD Application Image Tags"  or  "Update Argo CD Application Manifests"
write_warning "Simulated Argo CD update - no Argo CD instance connected yet"
echo "Would update Argo CD Applications annotated with:"
echo "  argo.octopus.com/project:     #{Octopus.Project.Slug}"
echo "  argo.octopus.com/environment: #{Octopus.Environment.Slug}"
echo "Image tag -> #{Octopus.Action.Package[podinfo].PackageVersion | Default latest}"
echo "git commit -m 'Octopus: #{Octopus.Project.Name} #{Octopus.Release.Number} -> #{Octopus.Environment.Name}'"
if [ "#{Demo.FailDeployment | Default False}" = "True" ]; then
  echo "  -> Starting new version... ERROR: health probe timed out after 30s (exit 137, OOMKilled)"
  fail_step "Deployment of #{Octopus.Project.Name} #{Octopus.Release.Number} failed on #{Octopus.Machine.Name | Default 'worker'}: container OOMKilled"
fi
sleep 2
write_highlight "Argo CD sync requested (simulated)"
