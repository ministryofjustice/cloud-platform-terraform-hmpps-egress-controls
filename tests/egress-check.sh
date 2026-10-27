#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
export MOCK_TRACE="$temporary/trace"
export MOCK_LOG_READS="$temporary/log-reads"
export MOCK_PAUSES="$temporary/pauses"

sleep() {
  [[ "$1" == 3 ]] || return 1
  printf 'pause\n' >> "$MOCK_PAUSES"
}
export -f sleep

kubectl() {
  while [[ $# -gt 0 ]]; do
    case "$1" in get|create|wait|exec|logs|delete) break ;; esac
    shift
  done
  case "$1" in
    get)
      case "$2" in
        secret)
          [[ "$MOCK_SCENARIO" != missing-secret ]] || return 1
          policy_enabled=true
          [[ "$MOCK_SCENARIO" != tcp-policy-disabled ]] || policy_enabled=false
          jq -n --argjson policy_enabled "$policy_enabled" '{
            namespace: "test", envoy_enabled: true, egress_controls_enabled: true,
            envoy_proxy_url: "http://hmpps-envoy-https-proxy.test.svc.cluster.local:3128",
            envoy_deployment_name: "hmpps-envoy-https-proxy",
            envoy_allowed_hosts_exact: ["allowed.example.com"],
            envoy_allowed_hosts_suffixes: [".approved.example.net"],
            vpc_egress_policy_enabled: $policy_enabled,
            vpc_egress_ports: [5432, 6379],
            vpc_egress_cidr_blocks: ["172.20.32.0/19"]
          }' | jq -c '{data: {"diagnostics.json": (tojson | @base64)}}'
          ;;
        deployment) printf '{"status":{"readyReplicas":2}}\n' ;;
        pod) printf '10.0.0.123' ;;
        *) return 1 ;;
      esac
      ;;
    create)
      jq -e '
        .metadata.labels.app == "egress-check" and
        .spec.containers[0].image == "ghcr.io/ministryofjustice/hmpps-devops-tools:latest" and
        .spec.containers[0].command == ["sh", "-c", "exec tail -f /dev/null"] and
        .spec.automountServiceAccountToken == false and
        .spec.securityContext.runAsNonRoot == true and
        .spec.containers[0].securityContext.readOnlyRootFilesystem == true and
        .spec.activeDeadlineSeconds >= 140
      ' >/dev/null || return 1
      printf 'created\n' >> "$MOCK_TRACE"
      [[ "$MOCK_SCENARIO" != create-uncertain ]] || return 1
      ;;
    wait) [[ "$MOCK_SCENARIO" != pod-failure ]] ;;
    exec)
      if [[ "$*" == *'getent ahostsv4'* ]]; then
        [[ "$*" == *"$MOCK_TCP_HOST"* ]] || return 1
        if [[ "$MOCK_SCENARIO" == tcp-dns-failure ]]; then
          return 0
        elif [[ "$MOCK_SCENARIO" == tcp-outside-vpc ]]; then
          printf '198.51.100.25 STREAM db.internal.test\n'
        elif [[ "$MOCK_SCENARIO" == tcp-mixed-answers ]]; then
          printf '198.51.100.25 STREAM db.internal.test\n172.20.35.10 STREAM db.internal.test\n'
        else
          printf '172.20.35.10 STREAM db.internal.test\n172.20.35.10 DGRAM db.internal.test\n'
        fi
      elif [[ "$*" == *'/dev/tcp/'* ]]; then
        [[ "$*" == *'timeout '* && "$*" == *"$MOCK_TCP_IP"* && "$*" == *"$MOCK_TCP_PORT"* ]] || return 1
        [[ "$MOCK_SCENARIO" != tcp-refused ]] || return 1
      else
        [[ "$*" == *'--disable'* && "$*" == *'--noproxy'* && "$*" == *'--proxy http://'* ]] || return 1
        [[ "$*" == *"$MOCK_URL"* ]] || return 1
        if [[ "$MOCK_SCENARIO" == tls-failure ]]; then
          printf '{"connect_status":"200","http_status":"000"}\n{"curl_exit":60}\n'
        elif [[ "$MOCK_SCENARIO" == timeout ]]; then
          printf '{"connect_status":"000","http_status":"000"}\n{"curl_exit":28}\n'
        elif [[ "$MOCK_ALLOWED" == false && "$MOCK_SCENARIO" != unexpected-allow ]]; then
          printf '{"connect_status":"403","http_status":"000"}\n{"curl_exit":56}\n'
        else
          printf '{"connect_status":"200","http_status":"401"}\n{"curl_exit":0}\n'
        fi
      fi
      ;;
    logs)
      [[ "$MOCK_SCENARIO" != tcp-pass && "$MOCK_SCENARIO" != tcp-refused && "$MOCK_SCENARIO" != tcp-dns-failure && "$MOCK_SCENARIO" != tcp-outside-vpc && "$MOCK_SCENARIO" != tcp-policy-disabled && "$MOCK_SCENARIO" != tcp-port-disabled ]] || return 1
      [[ "$*" == *'--since=5m'* ]] || return 1
      printf 'read\n' >> "$MOCK_LOG_READS"
      [[ "$MOCK_SCENARIO" != log-permission ]] || return 1
      [[ "$MOCK_SCENARIO" != missing-log ]] || return 0
      if [[ "$MOCK_SCENARIO" == delayed-log && $(wc -l < "$MOCK_LOG_READS") -eq 1 ]]; then
        return 0
      fi
      if [[ "$MOCK_SCENARIO" == runtime-only ]]; then
        printf 'non-JSON Envoy runtime message\n'
        printf '42\n{"message":"JSON runtime message"}\n'
        return 0
      fi
      local log_status=200 details=via_upstream
      if [[ "$MOCK_ALLOWED" == false && "$MOCK_SCENARIO" != unexpected-allow ]]; then
        log_status=403
        details='rbac_access_denied_matched_policy[none]'
      fi
      [[ "$MOCK_SCENARIO" != other-denial ]] || details=other_failure
      printf 'non-JSON Envoy runtime message\n'
      jq -cn --arg host "$MOCK_HOST" --arg started "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
        --arg details "$details" --argjson status "$log_status" '{
        authority: ($host + ":443"), downstream_client_ip: "10.0.0.123",
        start_time: $started, response_code: $status, response_code_details: $details
      }' | jq -c --arg scenario "$MOCK_SCENARIO" '
        (if $scenario == "unrelated-logs" then empty else . end),
        (. + {downstream_client_ip: "10.0.0.124", response_code_details: "wrong-client"}),
        (. + {start_time: "2000-01-01T00:00:00.000Z", response_code_details: "old-log"})'
      ;;
    delete) printf 'deleted\n' >> "$MOCK_TRACE" ;;
    *) return 1 ;;
  esac
}
export -f kubectl

run_check() {
  local scenario=$1 host=$2 allowed=$3 expected_exit=$4 expected_message=$5
  local output status url
  url="https://${host}/health/check?probe=egress"
  export MOCK_SCENARIO="$scenario" MOCK_HOST="$host" MOCK_ALLOWED="$allowed" MOCK_URL="$url"
  : > "$MOCK_TRACE"
  : > "$MOCK_LOG_READS"
  : > "$MOCK_PAUSES"
  if output=$(bash "$root/scripts/egress-check.sh" --namespace test --url "$url" 2>&1); then
    status=0
  else
    status=$?
  fi
  if [[ "$status" != "$expected_exit" || "$output" != *"$expected_message"* ]]; then
    printf 'FAIL %s: expected exit %s and message %s; got exit %s\n%s\n' "$scenario" "$expected_exit" "$expected_message" "$status" "$output"
    exit 1
  fi
  if [[ "$output" == *wrong-client* || "$output" == *old-log* ]]; then
    printf 'FAIL %s: unrelated access logs included\n' "$scenario"
    exit 1
  fi
  if [[ "$scenario" == allowed && "$output" != *'Retrieved 4 Envoy log lines; 3 JSON access logs'* ]]; then
    printf 'FAIL %s: expected log retrieval counts missing\n%s\n' "$scenario" "$output"
    exit 1
  fi
  if [[ "$scenario" == delayed-log && $(wc -l < "$MOCK_LOG_READS") -ne 2 ]]; then
    printf 'FAIL delayed-log: expected two log reads\n'
    exit 1
  fi
  if [[ "$scenario" == delayed-log && $(wc -l < "$MOCK_PAUSES") -ne 1 ]]; then
    printf 'FAIL delayed-log: expected a pause between log reads\n'
    exit 1
  fi
  if [[ "$scenario" == missing-log && $(wc -l < "$MOCK_LOG_READS") -ne 3 ]]; then
    printf 'FAIL missing-log: expected three bounded log reads\n'
    exit 1
  fi
  if [[ "$scenario" == missing-log && $(wc -l < "$MOCK_PAUSES") -ne 2 ]]; then
    printf 'FAIL missing-log: expected two bounded pauses\n'
    exit 1
  fi
  if [[ "$scenario" != missing-secret ]]; then
    [[ $(< "$MOCK_TRACE") == $'created\ndeleted' ]] || { printf 'FAIL %s: pod was not cleaned up\n' "$scenario"; exit 1; }
  fi
  printf 'PASS %s (%s)\n' "$scenario" "$host"
}

run_check allowed allowed.example.com true 0 'destination HTTP status 401 is separate from Envoy'
run_check suffix child.approved.example.net true 0 'matches the configured allowlist'
run_check suffix-apex approved.example.net false 0 'confirm the expected host allowlist denial'
run_check denied blocked.example.com false 0 'confirm the expected host allowlist denial'
run_check unexpected-allow blocked.example.com false 1 'Proxy accepted a destination absent'
run_check other-denial blocked.example.com false 2 'logs do not confirm an RBAC denial'
run_check tls-failure allowed.example.com true 1 'CONNECT succeeded but the HTTPS exchange failed'
run_check timeout allowed.example.com true 1 'did not establish a CONNECT tunnel'
run_check missing-log allowed.example.com true 2 'kubectl returned no Envoy log lines'
run_check delayed-log allowed.example.com true 0 'Envoy JSON access logs are visible and include the test request'
run_check runtime-only allowed.example.com true 2 'Logs received, but none use the expected JSON access-log format'
run_check unrelated-logs allowed.example.com true 2 'Envoy access logs are visible, but no entry matches'
run_check log-permission allowed.example.com true 2 'Cannot read Envoy logs'
run_check pod-failure allowed.example.com true 2 'Diagnostic pod did not become ready'
run_check missing-secret allowed.example.com true 2 'Cannot read diagnostic Secret'

run_tcp_check() {
  local scenario=$1 target=$2 expected_exit=$3 expected_message=$4 creates_pod=$5
  local output status tcp_host tcp_port
  tcp_host=${target%:*}
  tcp_port=${target##*:}
  export MOCK_SCENARIO="$scenario" MOCK_TCP_HOST="$tcp_host" MOCK_TCP_PORT="$tcp_port" MOCK_TCP_IP=172.20.35.10
  : > "$MOCK_TRACE"
  : > "$MOCK_LOG_READS"
  if output=$(bash "$root/scripts/egress-check.sh" --namespace test --tcp "$target" 2>&1); then
    status=0
  else
    status=$?
  fi
  if [[ "$status" != "$expected_exit" || "$output" != *"$expected_message"* ]]; then
    printf 'FAIL %s: expected exit %s and message %s; got exit %s\n%s\n' "$scenario" "$expected_exit" "$expected_message" "$status" "$output"
    exit 1
  fi
  if [[ "$creates_pod" == true ]]; then
    [[ $(< "$MOCK_TRACE") == $'created\ndeleted' ]] || { printf 'FAIL %s: TCP pod was not cleaned up\n' "$scenario"; exit 1; }
    [[ ! -s "$MOCK_LOG_READS" ]] || { printf 'FAIL %s: direct TCP check unexpectedly read Envoy logs\n' "$scenario"; exit 1; }
  else
    [[ ! -s "$MOCK_TRACE" ]] || { printf 'FAIL %s: rejected TCP configuration created a pod\n' "$scenario"; exit 1; }
  fi
  printf 'PASS %s (%s)\n' "$scenario" "$target"
}

run_tcp_check tcp-pass db.internal.test:5432 0 'TCP connection to db.internal.test:5432 succeeded' true
run_tcp_check tcp-refused db.internal.test:6379 1 'TCP connection to db.internal.test:6379 failed' true
run_tcp_check tcp-dns-failure db.internal.test:5432 1 'DNS returned no IPv4 addresses' true
run_tcp_check tcp-outside-vpc db.internal.test:5432 1 'outside the discovered VPC CIDRs' true
run_tcp_check tcp-mixed-answers db.internal.test:5432 0 'TCP connection to db.internal.test:5432 succeeded (connected to 172.20.35.10)' true
run_tcp_check tcp-policy-disabled db.internal.test:5432 1 'not enabled by the diagnostic VPC egress policy' false
run_tcp_check tcp-port-disabled db.internal.test:3306 1 'not enabled by the diagnostic VPC egress policy' false

export MOCK_SCENARIO=create-uncertain MOCK_URL=https://allowed.example.com/health MOCK_HOST=allowed.example.com MOCK_ALLOWED=true
: > "$MOCK_TRACE"
if output=$(bash "$root/scripts/egress-check.sh" --namespace test --url "$MOCK_URL" 2>&1); then
  printf 'FAIL create-uncertain: expected create error\n%s\n' "$output"
  exit 1
else
  status=$?
fi
if [[ "$status" != 2 || "$output" != *'Cannot create the diagnostic pod'* || $(< "$MOCK_TRACE") != $'created\ndeleted' ]]; then
  printf 'FAIL create-uncertain: failed create did not request pod cleanup\n%s\n' "$output"
  exit 1
fi
printf 'PASS create-uncertain (cleanup requested after ambiguous create)\n'

for bad_url in 'http://example.com/' 'https://example.com:8443/' 'https://user@example.com/' 'https://example.com/#fragment' 'https://*.example.com/'; do
  if bash "$root/scripts/egress-check.sh" --namespace test --url "$bad_url" >/dev/null 2>&1; then
    printf 'FAIL invalid URL accepted: %s\n' "$bad_url"
    exit 1
  else
    [[ $? == 2 ]] || exit 1
  fi
done
printf 'PASS invalid URL validation\n'