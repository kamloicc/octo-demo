#!/bin/bash
# Simulated ITSM change request. Swap for the native ServiceNow / Jira Service
# Management integration when configured on the instance.
TICKET="#{Change.Ticket | Default ''}"
if [ -z "$TICKET" ]; then
  TICKET="CHG$(date +%y%m%d%H%M)"
  echo "No change ticket supplied, raising standard change $TICKET"
else
  echo "Validating supplied change ticket $TICKET"
fi
sleep 2
echo "  State: Scheduled | Risk: Low | CAB: Approved | Window: now"
set_octopusvariable "ChangeTicket" "$TICKET"
write_highlight "Change $TICKET approved for #{Octopus.Project.Name} #{Octopus.Release.Number} -> #{Octopus.Environment.Name}"
