#!/bin/bash
# Simulated container / dependency scan producing SBOM + report artifacts.
echo "Generating SBOM (CycloneDX) for #{Octopus.Project.Name} #{Octopus.Release.Number}"
cat > sbom.json <<JSON
{ "bomFormat": "CycloneDX", "specVersion": "1.5", "metadata": { "component": { "name": "#{Octopus.Project.Name}", "version": "#{Octopus.Release.Number}" } },
  "components": [ { "name": "openssl", "version": "3.0.13" }, { "name": "log4j-core", "version": "2.23.1" }, { "name": "express", "version": "4.21.0" } ] }
JSON
echo "Scanning 3 components... CRITICAL: 0  HIGH: 0  MEDIUM: 2  LOW: 5"
printf "CRITICAL 0\nHIGH 0\nMEDIUM 2\nLOW 5\n" > scan-summary.txt
new_octopusartifact "$(pwd)/sbom.json" "sbom-#{Octopus.Release.Number}.json"
new_octopusartifact "$(pwd)/scan-summary.txt" "scan-summary.txt"
if [ "#{Demo.FailSecurityScan | Default False}" = "True" ]; then
  fail_step "Policy violation: CRITICAL CVE-2026-0001 found in openssl"
fi
write_highlight "Security gate passed (no CRITICAL/HIGH findings)"
