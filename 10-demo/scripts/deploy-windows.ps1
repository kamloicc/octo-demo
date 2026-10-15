# Simulated Windows service / IIS deployment on a Windows worker.
$app = "#{Octopus.Project.Name}"; $env = "#{Octopus.Environment.Name}"; $rel = "#{Octopus.Release.Number}"
Write-Highlight "Deploying $app $rel to $env (#{Octopus.Machine.Name | Default 'worker'})"
"Stopping Windows service #{Service.Name | Default 'ForgeScadaGateway'}", "Backing up config", "Applying XML transforms (web.$env.config)", "Starting service", "Verifying OPC-UA endpoint" |
  ForEach-Object { Write-Host "  -> $_"; Start-Sleep -Seconds 1 }
if ("#{Demo.FailDeployment | Default False}" -eq "True") { Fail-Step "Service #{Service.Name | Default 'ForgeScadaGateway'} failed to start (error 1053)" }
Set-OctopusVariable -name "DeployedVersion" -value $rel
Write-Highlight "$app $rel running"
