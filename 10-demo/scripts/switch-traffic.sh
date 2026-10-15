#!/bin/bash
# Simulated blue/green traffic switch on a load balancer.
LIVE="#{Octopus.Action[Determine live slot].Output.LiveSlot}"
IDLE="#{Octopus.Action[Determine live slot].Output.IdleSlot}"
echo "Load balancer #{LoadBalancer.Name | Default 'lb-storefront'}: shifting traffic $LIVE -> $IDLE"
for p in 10 25 50 100; do echo "  $IDLE weight: $p%"; sleep 1; done
write_highlight "$IDLE is now LIVE. $LIVE kept warm for instant rollback."
