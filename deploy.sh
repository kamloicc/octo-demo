#!/usr/bin/env bash
# Build (or rebuild) the whole demo space.
# Usage: OCTOPUS_URL=https://x.octopus.app OCTOPUS_API_KEY=API-xxx ./deploy.sh
set -euo pipefail
# Load local secrets (never committed): OCTOPUS_URL, OCTOPUS_API_KEY, TF_VAR_ghcr_*
[ -f "$(dirname "$0")/.env" ] && set -a && . "$(dirname "$0")/.env" && set +a
: "${OCTOPUS_URL:?set OCTOPUS_URL}" "${OCTOPUS_API_KEY:?set OCTOPUS_API_KEY}"
OCTOPUS_URL="${OCTOPUS_URL%/}"   # strip trailing slash
export TF_VAR_octopus_url="$OCTOPUS_URL" TF_VAR_octopus_api_key="$OCTOPUS_API_KEY"
cd "$(dirname "$0")"

# Make the API key's user a Space Manager of the new space (otherwise stage 10
# fails with "User does not have access to space" on Octopus Cloud)
if ! RESP=$(curl -fsS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" "$OCTOPUS_URL/api/users/me" 2>&1); then
  echo "ERROR: Octopus rejected the API key for $OCTOPUS_URL ($RESP)."
  echo "Check OCTOPUS_API_KEY in .env: it must be a current key (Profile > My API Keys), no quotes or spaces."
  exit 1
fi
ME=$(echo "$RESP" | grep -oE '"Id" *: *"Users-[0-9]+"' | head -1 | grep -oE 'Users-[0-9]+')
[ -n "$ME" ] || { echo "Could not resolve the API key user"; exit 1; }
echo "API key user: $ME"
export TF_VAR_space_manager_user_ids="[\"$ME\"]" TF_VAR_demo_user_ids="[\"$ME\"]"

terraform -chdir=00-space init -upgrade -input=false
terraform -chdir=00-space apply -auto-approve -input=false
export TF_VAR_space_id="$(terraform -chdir=00-space output -raw space_id)"
echo "Space: $TF_VAR_space_id"

terraform -chdir=10-demo init -upgrade -input=false
terraform -chdir=10-demo apply -auto-approve -input=false -parallelism=4
OCTOPUS_URL="$OCTOPUS_URL" python3 upload-logos.py || echo "Logo upload failed (non-fatal)"
echo "Done. Open $OCTOPUS_URL/app#/$TF_VAR_space_id/projects"
