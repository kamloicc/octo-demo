#!/bin/bash
# Simulated smoke test. Set prompted variable Demo.FailSmokeTest=True to show
# guided failure, failure analysis and rollback.
URL="#{App.Url | Default 'https://example.com'}"
echo "Running smoke tests against $URL"
for t in "GET /healthz" "GET /api/version" "POST /api/login" "GET /metrics"; do
  echo "  [PASS] $t"; sleep 1
done
if [ "#{Demo.FailSmokeTest | Default False}" = "True" ]; then
  echo "  [FAIL] GET /api/orders -> 503 Service Unavailable (connection pool exhausted: DB_MAX_CONNECTIONS=5)"
  fail_step "Smoke test failed: /api/orders returned 503. Check DB connection pool sizing."
fi
echo "  [PASS] GET /api/orders"
write_highlight "All smoke tests passed for #{Octopus.Release.Number}"
