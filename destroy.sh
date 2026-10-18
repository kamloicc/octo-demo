#!/usr/bin/env bash
# Tear everything down (releases/deployments created during demos are removed with the space).
set -euo pipefail
[ -f "$(dirname "$0")/.env" ] && set -a && . "$(dirname "$0")/.env" && set +a
: "${OCTOPUS_URL:?}" "${OCTOPUS_API_KEY:?}"
export TF_VAR_octopus_url="$OCTOPUS_URL" TF_VAR_octopus_api_key="$OCTOPUS_API_KEY"
cd "$(dirname "$0")"
export TF_VAR_space_id="$(terraform -chdir=00-space output -raw space_id)"
terraform -chdir=10-demo destroy -auto-approve -input=false || true
# A space must have its task queue stopped before deletion
terraform -chdir=00-space apply -auto-approve -input=false -var is_task_queue_stopped=true 2>/dev/null || true
terraform -chdir=00-space destroy -auto-approve -input=false
