#!/usr/bin/env bash
set -euo pipefail

HOST="http://127.0.0.1:8080"
N=${1:-50}

echo "═══════════════════════════════════════════════════════"
echo "  Cú Chulainn (Pony) — Benchmark Suite"
echo "═══════════════════════════════════════════════════════"
echo "  Requests per test : $N"
echo "═══════════════════════════════════════════════════════"
echo ""

run_test() {
  local label="$1" url="$2" method="${3:-GET}"

  echo -n "── $label ... "

  local total=0 min="9999" max="0" success=0 fail=0
  for (( i=0; i<N; i++ )); do
    local result
    result=$(curl -s --max-time 2 -o /dev/null -w "%{http_code} %{time_total}" -X "$method" "$url" 2>/dev/null || echo "000 0")
    local code time
    code="${result%% *}"
    time="${result##* }"

    local ms
    ms=$(awk "BEGIN {printf \"%.2f\", $time * 1000}")
    total=$(awk "BEGIN {printf \"%.2f\", $total + $ms}")
    min=$(awk "BEGIN {print ($ms < $min) ? $ms : $min}")
    max=$(awk "BEGIN {print ($ms > $max) ? $ms : $max}")

    if [[ "$code" == "200" ]]; then ((success++)) || true
    else ((fail++)) || true; fi
  done

  local avg
  avg=$(awk "BEGIN {printf \"%.2f\", $total / $N}")
  local rps
  rps=$(awk "BEGIN {printf \"%.0f\", $N / ($total / 1000)}")

  echo "avg=${avg}ms min=${min}ms max=${max}ms 2xx=$success fail=$fail rps≈$rps"
}

echo "--- Sequential ---"
run_test "GET / (root dir listing)"                  "$HOST/"
run_test "GET /index.html (static file)"              "$HOST/index.html"
run_test "GET /style.css (CSS file)"                  "$HOST/style.css"
run_test "GET /nonexistent (404)"                     "$HOST/nonexistent"
run_test "GET /../../../etc/passwd (traversal)"       "$HOST/../../../etc/passwd"
run_test "POST / (405 Method Not Allowed)"            "$HOST/" "POST"

echo ""
echo "--- Concurrent Burst (50 simultaneous GET /) ---"
echo -n "  Launching ... "
pids=()
start_time=$(date +%s%N)
for (( i=0; i<50; i++ )); do
  curl -s --max-time 5 -o /dev/null "$HOST/" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
end_time=$(date +%s%N)
elapsed=$(awk "BEGIN {printf \"%.3f\", ($end_time - $start_time) / 1000000000}")
rps=$(awk "BEGIN {printf \"%.0f\", 50 / $elapsed}")
echo "total=${elapsed}s rps≈$rps"

echo ""
echo "Done."
