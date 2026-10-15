#!/bin/bash
# Simulated Terraform plan/apply for platform provisioning runbooks.
echo "terraform init  -backend-config=key=#{Octopus.Environment.Name | ToLower}/#{Infra.Stack | Default 'landing-zone'}.tfstate"
echo "terraform plan  -var env=#{Octopus.Environment.Name | ToLower} -var size=#{Infra.Size | Default 'small'}"
cat > plan.txt <<TXT
  + azurerm_resource_group.app
  + azurerm_kubernetes_cluster.aks (node_count = #{Infra.NodeCount | Default 3})
  + azurerm_postgresql_flexible_server.db
  + azurerm_key_vault.kv
Plan: 4 to add, 0 to change, 0 to destroy.
TXT
cat plan.txt
new_octopusartifact "$(pwd)/plan.txt" "terraform-plan-#{Octopus.Environment.Name}.txt"
echo "terraform apply -auto-approve"; sleep 3
write_highlight "Provisioned #{Infra.Stack | Default 'landing-zone'} in #{Octopus.Environment.Name}"
