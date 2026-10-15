#!/bin/bash
# Simulated canary analysis against observability metrics.
echo "Querying #{Observability.Url | Default 'https://metrics.example.com'} for canary vs baseline (5 min window)"
sleep 2
echo "  error_rate   canary=0.21%  baseline=0.24%   OK"
echo "  p95_latency  canary=182ms  baseline=190ms   OK"
echo "  cpu          canary=41%    baseline=44%     OK"
if [ "#{Demo.FailCanary | Default False}" = "True" ]; then
  fail_step "Canary error rate 4.8% exceeds threshold 1%. Halting rollout."
fi
write_highlight "Canary healthy - promoting to remaining fleet"
