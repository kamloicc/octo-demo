#!/bin/bash
# Simulated application deployment. Runs on a dynamic worker, on behalf of the
# (cloud region) target if the step is target-scoped.
set -e
APP="#{Octopus.Project.Name}"
ENV="#{Octopus.Environment.Name}"
REL="#{Octopus.Release.Number}"
TARGET="#{Octopus.Machine.Name | Default 'worker'}"
TENANT="#{Octopus.Deployment.Tenant.Name | Default 'untenanted'}"
URL="#{App.Url | Default 'n/a'}"

write_highlight "Deploying $APP $REL to $ENV ($TARGET, tenant: $TENANT)"
echo "Target URL      : $URL"
echo "Config profile  : #{App.ConfigProfile | Default 'default'}"
echo "Feature flags   : #{App.FeatureFlags | Default 'none'}"
echo "Image / package : #{Octopus.Action.Package[app].PackageId | Default 'inline'}:#{Octopus.Action.Package[app].PackageVersion | Default $REL}"
for stage in "Pulling artifact" "Rendering configuration" "Stopping old version" "Starting new version" "Warming caches"; do
  echo "  -> $stage..."; sleep 1
done

if [ "#{Demo.FailDeployment | Default False}" = "True" ]; then
  echo "  -> Starting new version... ERROR: health probe timed out after 30s (exit 137, OOMKilled)"
  fail_step "Deployment of #{Octopus.Project.Name} #{Octopus.Release.Number} failed on #{Octopus.Machine.Name | Default 'worker'}: container OOMKilled"
fi
cat > deployment-manifest.json <<JSON
{ "app": "$APP", "release": "$REL", "environment": "$ENV", "target": "$TARGET", "tenant": "$TENANT", "deployedAt": "$(date -u +%FT%TZ)" }
JSON
new_octopusartifact "$(pwd)/deployment-manifest.json" "manifest-$TARGET.json"
set_octopusvariable "DeployedVersion" "$REL"
write_highlight "$APP $REL is live on $TARGET"
