#!/bin/bash
set -e

BASE_URL="${BASE_URL:-http://localhost:6868}"
PRODUCT_ID="${PRODUCT_ID:-test-product-uuid}"

echo "========================================"
echo "K6 Performance Tests - E-Commerce SUT"
echo "========================================"
echo "Gateway: $BASE_URL"
echo "Product ID: $PRODUCT_ID"
echo "========================================"

run_test() {
  local scenario=$1
  local timestamp=$(date +%Y%m%d_%H%M%S)

  echo ""
  echo "=== Running $scenario ==="
  echo "Started at: $(date)"

  k6 run \
    -e BASE_URL=$BASE_URL \
    -e PRODUCT_ID=$PRODUCT_ID \
    --out json=results/${scenario}-${timestamp}.json \
    --summary-export=results/${scenario}-${timestamp}-summary.json \
    scenarios/${scenario}.js

  echo "Completed at: $(date)"
  echo "Results saved to: results/${scenario}-${timestamp}.json"
}

# Create results directory
mkdir -p results

case "$1" in
  smoke)
    run_test "smoke-test"
    ;;
  load)
    run_test "load-test"
    ;;
  stress)
    run_test "stress-test"
    ;;
  spike)
    run_test "spike-test"
    ;;
  all)
    run_test "smoke-test"
    echo ""
    echo "Smoke test passed. Proceeding to load test..."
    sleep 10
    run_test "load-test"
    echo ""
    echo "Load test passed. Proceeding to stress test..."
    sleep 10
    run_test "stress-test"
    echo ""
    echo "Stress test passed. Proceeding to spike test..."
    sleep 10
    run_test "spike-test"
    ;;
  *)
    echo "Usage: $0 {smoke|load|stress|spike|all}"
    echo ""
    echo "Options:"
    echo "  smoke  - Quick validation (2 VUs, 1 min)"
    echo "  load   - Sustained load test (50 VUs, 15 min)"
    echo "  stress - Find breaking point (up to 200 VUs, 20 min)"
    echo "  spike  - Traffic spike test (10→100 VUs)"
    echo "  all    - Run all tests sequentially"
    exit 1
    ;;
esac

echo ""
echo "========================================"
echo "All tests completed!"
echo "Results saved to: results/"
echo "========================================"
