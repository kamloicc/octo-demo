#!/bin/bash
# Blue/green: alternate slots per release number parity.
PATCH=$(echo "#{Octopus.Release.Number}" | awk -F. '{print $NF}' | tr -dc '0-9')
if [ $(( ${PATCH:-0} % 2 )) -eq 0 ]; then LIVE=blue; IDLE=green; else LIVE=green; IDLE=blue; fi
set_octopusvariable "LiveSlot" "$LIVE"
set_octopusvariable "IdleSlot" "$IDLE"
write_highlight "Live slot: $LIVE. Deploying to idle slot: $IDLE"
