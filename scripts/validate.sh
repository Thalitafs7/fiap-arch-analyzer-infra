#!/usr/bin/env bash
# validate.sh — Validates all Arch Analyzer services through the ALB.
#
# For each service (excluding celery-worker), sends:
#   GET http://<alb_dns>/api/<service>/health  (5-second timeout)
# Retries every 10 seconds for up to 5 minutes.
# Records PASS (with latency ms) or FAIL (with last error).
# Emits JSON and Markdown reports to ./artifacts/.
#
# Requirements: 16.1, 16.2, 16.3, 16.4, 16.5, 16.6
#
# Usage:
#   ./validate.sh [ALB_DNS] [ARTIFACTS_DIR]
#
# If ALB_DNS is omitted, reads from: terraform output -raw alb_dns_name
# ARTIFACTS_DIR defaults to ./artifacts

set -euo pipefail

# ---------------------------------------------------------------------------
# Dependencies check
# ---------------------------------------------------------------------------
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not installed." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
ALB_DNS="${1:-}"
ARTIFACTS_DIR="${2:-./artifacts}"

TIMEOUT_SEC=5      # per-request timeout  (Req 16.1)
RETRY_INTERVAL=10  # sleep between retries (Req 16.2)
MAX_WAIT_SEC=300   # 5 minutes total       (Req 16.2)

# ---------------------------------------------------------------------------
# Services to validate (celery-worker excluded per Req 16.1)
# Format: "name|health_url"
# ---------------------------------------------------------------------------
SERVICES=(
    "auth-service|/api/auth/health"
    "api-gateway|/api/gateway/health"
    "registration-service|/api/registration/health"
    "processing-service|/api/analyses/health"
    "report-service|/api/reports/health"
)

# ---------------------------------------------------------------------------
# Resolve ALB DNS
# ---------------------------------------------------------------------------
if [[ -z "$ALB_DNS" ]]; then
    echo "Reading ALB DNS from terraform output..."
    ALB_DNS=$(terraform output -raw alb_dns_name 2>&1 | tr -d '[:space:]')
    if [[ -z "$ALB_DNS" ]]; then
        echo "ERROR: terraform output -raw alb_dns_name returned empty." >&2
        exit 1
    fi
fi

echo "ALB DNS: $ALB_DNS"

# ---------------------------------------------------------------------------
# Ensure artifacts directory exists
# ---------------------------------------------------------------------------
mkdir -p "$ARTIFACTS_DIR"

# ---------------------------------------------------------------------------
# Validate each service
# ---------------------------------------------------------------------------
# Accumulate results as a JSON array string
RESULTS_JSON="[]"
TIMESTAMP_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TIMESTAMP_FILE=$(date -u +"%Y%m%d-%H%M%S")

for entry in "${SERVICES[@]}"; do
    SVC_NAME="${entry%%|*}"
    HEALTH_PATH="${entry##*|}"
    URL="http://${ALB_DNS}${HEALTH_PATH}"

    echo ""
    echo "==> Validating ${SVC_NAME} at ${URL}"

    START_EPOCH=$(date +%s)
    PASSED=false
    LATENCY_MS=""
    LAST_ERROR=""

    while true; do
        NOW_EPOCH=$(date +%s)
        ELAPSED=$(( NOW_EPOCH - START_EPOCH ))

        # Perform the HTTP request; capture HTTP status code and latency
        REQ_START=$(date +%s%3N)  # milliseconds
        HTTP_CODE=$(curl \
            --silent \
            --output /dev/null \
            --write-out "%{http_code}" \
            --max-time "$TIMEOUT_SEC" \
            --connect-timeout "$TIMEOUT_SEC" \
            "$URL" 2>/dev/null) || HTTP_CODE="000"
        REQ_END=$(date +%s%3N)
        LATENCY_MS=$(( REQ_END - REQ_START ))

        if [[ "$HTTP_CODE" == "200" ]]; then
            echo "  PASS  latency=${LATENCY_MS}ms  status=${HTTP_CODE}"
            RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
                --arg svc  "$SVC_NAME" \
                --arg url  "$URL" \
                --argjson lat "$LATENCY_MS" \
                '. + [{"service": $svc, "status": "PASS", "latency_ms": $lat, "error": null, "url": $url}]')
            PASSED=true
            break
        else
            if [[ "$HTTP_CODE" == "000" ]]; then
                LAST_ERROR="connection error or timeout"
            else
                LAST_ERROR="HTTP ${HTTP_CODE}"
            fi
            echo "  retry  status=${HTTP_CODE}  elapsed=${ELAPSED}s"
        fi

        # Check timeout AFTER the attempt so we always try at least once
        if (( ELAPSED >= MAX_WAIT_SEC )); then
            break
        fi

        sleep "$RETRY_INTERVAL"
    done

    if [[ "$PASSED" == "false" ]]; then
        echo "  FAIL  last_error=${LAST_ERROR}"
        RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
            --arg svc "$SVC_NAME" \
            --arg url "$URL" \
            --arg err "$LAST_ERROR" \
            '. + [{"service": $svc, "status": "FAIL", "latency_ms": null, "error": $err, "url": $url}]')
    fi
done

# ---------------------------------------------------------------------------
# Determine overall result  (Req 16.5)
# ---------------------------------------------------------------------------
FAIL_COUNT=$(echo "$RESULTS_JSON" | jq '[.[] | select(.status != "PASS")] | length')
if [[ "$FAIL_COUNT" -eq 0 ]]; then
    OVERALL="true"
    OVERALL_TEXT="PASS"
else
    OVERALL="false"
    OVERALL_TEXT="FAIL"
fi

# ---------------------------------------------------------------------------
# Build full report object
# ---------------------------------------------------------------------------
REPORT_JSON=$(jq -n \
    --arg  ts      "$TIMESTAMP_ISO" \
    --arg  dns     "$ALB_DNS" \
    --argjson ov   "$OVERALL" \
    --argjson items "$RESULTS_JSON" \
    '{timestamp: $ts, alb_dns: $dns, overall: $ov, items: $items}')

# ---------------------------------------------------------------------------
# Emit JSON report  (Req 16.6)
# ---------------------------------------------------------------------------
JSON_PATH="${ARTIFACTS_DIR}/validation-report-${TIMESTAMP_FILE}.json"
echo "$REPORT_JSON" | jq '.' > "$JSON_PATH"
echo ""
echo "JSON report: $JSON_PATH"

# ---------------------------------------------------------------------------
# Emit Markdown report  (Req 16.6)
# ---------------------------------------------------------------------------
MD_PATH="${ARTIFACTS_DIR}/validation-report-${TIMESTAMP_FILE}.md"

if [[ "$OVERALL" == "true" ]]; then
    OVERALL_EMOJI=":white_check_mark:"
else
    OVERALL_EMOJI=":x:"
fi

{
    echo "# Arch Analyzer Validation Report"
    echo ""
    echo "| Field     | Value |"
    echo "|-----------|-------|"
    echo "| Timestamp | ${TIMESTAMP_ISO} |"
    echo "| ALB DNS   | ${ALB_DNS} |"
    echo "| Overall   | ${OVERALL_EMOJI} **${OVERALL_TEXT}** |"
    echo ""
    echo "## Service Results"
    echo ""
    echo "| Service | Status | Latency (ms) | Error |"
    echo "|---------|--------|-------------|-------|"

    echo "$RESULTS_JSON" | jq -r '.[] |
        if .status == "PASS" then
            "| \(.service) | :white_check_mark: PASS | \(.latency_ms) | — |"
        else
            "| \(.service) | :x: FAIL | — | \(.error // "unknown") |"
        end'

    echo ""
    echo "---"
    echo "_Generated by validate.sh_"
} > "$MD_PATH"

echo "Markdown report: $MD_PATH"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "Overall: ${OVERALL_TEXT}"
echo "========================================"

# Exit non-zero when any service failed so CI can detect failures
if [[ "$OVERALL" == "false" ]]; then
    exit 1
fi
exit 0
