#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: bash scripts/egress-check.sh --namespace NAME (--url URL | --tcp HOST:PORT) [options]' \
    '' \
    '  --image IMAGE      Diagnostic image (default: ghcr.io/ministryofjustice/hmpps-devops-tools:latest)' \
    '  --secret NAME      Diagnostic Secret (default: hmpps-egress-diagnostics)' \
    '  --timeout SECONDS  Connection timeout, 1-300 (default: 20)' \
    '  --help             Show this help' \
    '' \
    'The diagnostic image must contain sh, tail, curl, bash, timeout, and getent.' \
    'Exit codes: 0 = expected behavior, 1 = failed check, 2 = inconclusive/setup error.'
}

namespace=''
url=''
tcp_target=''
host=''
tcp_host=''
tcp_port=''
image=ghcr.io/ministryofjustice/hmpps-devops-tools:latest
secret=hmpps-egress-diagnostics
timeout=20
failed=0
inconclusive=0
pod_created=false

report() {
  printf '%-12s %s\n' "$1" "$2"
  case "$1" in
    FAIL) failed=1 ;;
    INCONCLUSIVE) inconclusive=1 ;;
  esac
}

abort() {
  report INCONCLUSIVE "$1"
  exit 2
}

ipv4_to_number() {
  local address=$1 octet1 octet2 octet3 octet4
  IFS=. read -r octet1 octet2 octet3 octet4 <<< "$address"
  [[ "$octet1" =~ ^[0-9]{1,3}$ && "$octet2" =~ ^[0-9]{1,3}$ && "$octet3" =~ ^[0-9]{1,3}$ && "$octet4" =~ ^[0-9]{1,3}$ ]] || return 1
  (( octet1 <= 255 && octet2 <= 255 && octet3 <= 255 && octet4 <= 255 )) || return 1
  printf '%u' "$(( (octet1 << 24) | (octet2 << 16) | (octet3 << 8) | octet4 ))"
}

ipv4_in_cidr() {
  local address_number network prefix network_number mask
  address_number=$(ipv4_to_number "$1") || return 1
  network=${2%/*}
  prefix=${2#*/}
  [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && (( prefix <= 32 )) || return 1
  network_number=$(ipv4_to_number "$network") || return 1
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  (( (address_number & mask) == (network_number & mask) ))
}

while (( $# > 0 )); do
  case "$1" in
    --help) usage; exit 0 ;;
    --namespace|--url|--tcp|--image|--secret|--timeout)
      (( $# >= 2 )) || abort "Missing value for $1"
      case "$1" in
        --namespace) namespace=$2 ;;
        --url) url=$2 ;;
        --tcp) tcp_target=$2 ;;
        --image) image=$2 ;;
        --secret) secret=$2 ;;
        --timeout) timeout=$2 ;;
      esac
      shift 2
      ;;
    *) usage; abort "Unknown option: $1" ;;
  esac
done

[[ -n "$namespace" && -n "$image" ]] || { usage; abort 'Namespace is required'; }
if [[ -n "$url" && -n "$tcp_target" ]] || [[ -z "$url" && -z "$tcp_target" ]]; then
  usage
  abort 'Provide exactly one of --url or --tcp'
fi
for executable in kubectl jq; do
  command -v "$executable" >/dev/null || abort "Required command not found: $executable"
done
if [[ ! "$timeout" =~ ^[1-9][0-9]{0,2}$ ]] || (( timeout > 300 )); then
  abort 'Timeout must be between 1 and 300 seconds'
fi
if [[ -n "$url" ]]; then
  if ! host=$(jq -ner --arg url "$url" '
    try ($url | capture("^https://(?<host>[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*)(?::443)?(?:[/?][^#]*)?$") | .host) catch empty
  ' 2>/dev/null); then
    abort 'URL must use https, contain a DNS hostname, and use the default port 443; fragments and credentials are not supported'
  fi
else
  tcp_host=${tcp_target%:*}
  tcp_port=${tcp_target##*:}
  if [[ "$tcp_host" == "$tcp_target" ]] || ! jq -ne --arg host "$tcp_host" '$host | test("^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*$")' >/dev/null 2>&1; then
    abort 'TCP target must be a DNS hostname or IPv4 address followed by :PORT'
  fi
  if [[ ! "$tcp_port" =~ ^[0-9]{1,5}$ ]] || (( 10#$tcp_port < 1 || 10#$tcp_port > 65535 )); then
    abort 'TCP port must be between 1 and 65535'
  fi
fi

kube=(kubectl --request-timeout="$((timeout + 120))s" --namespace "$namespace")

if ! secret_json=$("${kube[@]}" get secret "$secret" -o json); then
  abort "Cannot read diagnostic Secret $secret"
fi
if ! diagnostics=$(printf '%s' "$secret_json" | jq -er '.data["diagnostics.json"] | @base64d | fromjson'); then
  abort 'Secret does not contain valid diagnostics.json'
fi
if ! printf '%s' "$diagnostics" | jq -e --arg namespace "$namespace" '
  .namespace == $namespace and .envoy_enabled == true and
  (.egress_controls_enabled | type == "boolean") and
  (.envoy_proxy_url | type == "string") and
  (.envoy_deployment_name | type == "string") and
  (.envoy_allowed_hosts_exact | type == "array") and
  (.envoy_allowed_hosts_suffixes | type == "array")
' >/dev/null; then
  abort 'Diagnostic configuration is invalid, belongs to another namespace, or has Envoy disabled'
fi
printf 'Diagnostic configuration:\n%s\n\n' "$diagnostics"
proxy_url=$(printf '%s' "$diagnostics" | jq -r '.envoy_proxy_url')
deployment=$(printf '%s' "$diagnostics" | jq -r '.envoy_deployment_name')
if [[ -n "$url" ]]; then
  allowed=false
  if printf '%s' "$diagnostics" | jq -e --arg host "$host" '
    any(.envoy_allowed_hosts_exact[]; . == $host) or
    any(.envoy_allowed_hosts_suffixes[]; . as $suffix | $host | endswith($suffix))
  ' >/dev/null; then
    allowed=true
    report INFO "$host matches the configured allowlist"
  else
    report INFO "$host does not match the configured allowlist; an RBAC denial is expected"
  fi
  report INFO 'This tests a temporary pod, not application-specific labels, settings, or clients'
else
  if ! printf '%s' "$diagnostics" | jq -e --argjson port "$tcp_port" '
    .vpc_egress_policy_enabled == true and any(.vpc_egress_ports[]; . == $port)
  ' >/dev/null; then
    report FAIL "TCP port $tcp_port is not enabled by the diagnostic VPC egress policy"
    exit 1
  fi
  report INFO "This tests direct TCP access to $tcp_host:$tcp_port from a temporary pod"
  report INFO 'Direct TCP traffic bypasses Envoy; no Envoy access log is expected'
fi

if [[ -n "$url" ]]; then
  if deployment_json=$("${kube[@]}" get deployment "$deployment" -o json); then
    if printf '%s' "$deployment_json" | jq -e '(.status.readyReplicas // 0) > 0' >/dev/null; then
      report PASS 'Envoy has ready replicas'
    else
      report FAIL 'Envoy has no ready replicas'
    fi
  else
    report INCONCLUSIVE 'Cannot inspect Envoy readiness'
  fi
fi

pod_name="egress-check-${RANDOM}-${RANDOM}"
cleanup() {
  if [[ "$pod_created" == true ]]; then
    if ! "${kube[@]}" delete pod "$pod_name" --wait=false --ignore-not-found >/dev/null; then
      printf 'Cleanup failed; delete pod %s in namespace %s manually.\n' "$pod_name" "$namespace" >&2
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pod_created=true
if ! jq -n --arg name "$pod_name" --arg namespace "$namespace" --arg image "$image" --argjson deadline "$((timeout + 120))" '{
  apiVersion: "v1", kind: "Pod",
  metadata: {name: $name, namespace: $namespace, labels: {app: "egress-check"}},
  spec: {
    restartPolicy: "Never", automountServiceAccountToken: false,
    activeDeadlineSeconds: $deadline,
    securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: {type: "RuntimeDefault"}},
    containers: [{
      name: "check", image: $image, command: ["sh", "-c", "exec tail -f /dev/null"],
      resources: {requests: {cpu: "10m", memory: "32Mi"}, limits: {cpu: "100m", memory: "64Mi"}},
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
    }]
  }
}' | "${kube[@]}" create -f - >/dev/null; then
  abort 'Cannot create the diagnostic pod'
fi
if ! "${kube[@]}" wait --for=condition=Ready "pod/$pod_name" --timeout=90s >/dev/null; then
  "${kube[@]}" get pod "$pod_name" -o wide >&2 || true
  abort 'Diagnostic pod did not become ready; check image pulls, admission rules, and pod events'
fi
pod_ip=$("${kube[@]}" get pod "$pod_name" -o jsonpath='{.status.podIP}')
[[ -n "$pod_ip" ]] || abort 'Diagnostic pod has no IP address'
if [[ -n "$url" ]]; then
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if result=$("${kube[@]}" exec "$pod_name" -c check -- sh -c "
  curl \"\$@\"
  curl_exit=\$?
  printf '{\"curl_exit\":%s}\\n' \"\$curl_exit\"
" sh --disable --silent --show-error --output /dev/null \
  --connect-timeout "$timeout" --max-time "$timeout" \
  --proxy "$proxy_url" --noproxy '' \
  --write-out '{"connect_status":"%{http_connect}","http_status":"%{http_code}"}\n' \
  "$url"); then
  if ! result=$(printf '%s' "$result" | jq -se 'add | select(has("connect_status") and has("http_status") and has("curl_exit"))'); then
    abort 'Curl did not return valid test results; check that the image contains curl'
  fi
else
  abort 'Cannot execute the HTTPS check in the diagnostic pod'
fi
connect_status=$(printf '%s' "$result" | jq -r '.connect_status')
curl_exit=$(printf '%s' "$result" | jq -r '.curl_exit')
http_status=$(printf '%s' "$result" | jq -r '.http_status')
report INFO "Envoy CONNECT status=$connect_status; destination HTTP status=$http_status; curl exit=$curl_exit"

if [[ "$allowed" == true ]]; then
  if [[ "$connect_status" == 200 ]]; then
    report PASS 'Proxy accepted CONNECT'
    if [[ "$curl_exit" == 0 ]]; then
      report PASS "HTTPS request completed; destination HTTP status $http_status is separate from Envoy's CONNECT decision"
    else
      report FAIL 'CONNECT succeeded but the HTTPS exchange failed; inspect the curl error above'
    fi
  else
    report FAIL 'Configured allowed destination did not establish a CONNECT tunnel'
  fi
elif [[ "$connect_status" == 200 ]]; then
  report FAIL 'Proxy accepted a destination absent from the diagnostic allowlist; check loaded configuration'
fi

report INFO "Reading Envoy logs: namespace=$namespace app=$deployment container=envoy window=5m"
report INFO "Matching test: client_ip=$pod_ip authority=$host:443 start_time=$started"
logs_readable=false
for attempt in 1 2 3; do
  if ! proxy_logs=$("${kube[@]}" logs -l "app=$deployment" -c envoy --since=5m --tail=-1 --max-log-requests=10); then
    report INCONCLUSIVE 'Cannot read Envoy logs across replicas'
    logs_readable=false
    break
  fi
  logs_readable=true
  log_summary=$(printf '%s\n' "$proxy_logs" | jq -Rsc '
    split("\n") | map(select(length > 0)) as $lines |
    {
      line_count: ($lines | length),
      access_logs: [$lines[] | fromjson? | select(type == "object") |
        select(has("authority") and has("start_time") and has("response_code"))]
    }
  ')
  line_count=$(printf '%s' "$log_summary" | jq '.line_count')
  access_log_count=$(printf '%s' "$log_summary" | jq '.access_logs | length')
  report INFO "Retrieved $line_count Envoy log lines; $access_log_count JSON access logs (attempt $attempt/3)"
  matched_logs=$(printf '%s' "$log_summary" | jq -c --arg ip "$pod_ip" --arg host "$host" --arg started "$started" '
    .access_logs | map(select(
      .downstream_client_ip == $ip and
      (.authority == $host or .authority == ($host + ":443")) and
      (.start_time // "")[0:19] >= $started[0:19]
    ))
  ')
  if [[ $(printf '%s' "$matched_logs" | jq 'length') -gt 0 ]]; then
    break
  fi
  if (( attempt < 3 )); then
    sleep 3
  fi
done
if [[ "$logs_readable" == true ]]; then
  if (( line_count == 0 )); then
    report INCONCLUSIVE 'kubectl returned no Envoy log lines in the last five minutes; log retrieval is not verified'
  elif (( access_log_count == 0 )); then
    report INCONCLUSIVE 'Logs received, but none use the expected JSON access-log format'
  elif [[ $(printf '%s' "$matched_logs" | jq 'length') -gt 0 ]]; then
    report PASS 'Envoy JSON access logs are visible and include the test request'
    printf '\nMatching Envoy access logs:\n'
    printf '%s' "$matched_logs" | jq '.[]'
    if [[ "$allowed" == false ]]; then
      if printf '%s' "$matched_logs" | jq -e 'any(.[]; (.response_code | tostring) == "403" and ((.response_code_details // "") | contains("rbac_access_denied")))' >/dev/null; then
        report PASS 'Envoy logs confirm the expected host allowlist denial'
      elif [[ "$connect_status" != 200 ]]; then
        report INCONCLUSIVE 'Connection failed, but logs do not confirm an RBAC denial'
      fi
    fi
  else
    report INCONCLUSIVE 'Envoy access logs are visible, but no entry matches the test IP, destination, and start time; logging may be delayed. This does not prove a Calico denial'
  fi
fi
else
  if ! resolved_ips=$("${kube[@]}" exec "$pod_name" -c check -- timeout "${timeout}s" getent ahostsv4 "$tcp_host" | awk '!seen[$1]++ {print $1}'); then
    report FAIL "Could not resolve $tcp_host from the diagnostic pod"
  elif [[ -z "$resolved_ips" ]]; then
    report FAIL "DNS returned no IPv4 addresses for $tcp_host"
  else
    report INFO "Resolved $tcp_host to: ${resolved_ips//$'\n'/, }"
    matched_cidr=''
    matched_ip=''
    for resolved_ip in $resolved_ips; do
      for cidr in $(printf '%s' "$diagnostics" | jq -r '.vpc_egress_cidr_blocks[]'); do
        if ipv4_in_cidr "$resolved_ip" "$cidr"; then
          matched_cidr=$cidr
          matched_ip=$resolved_ip
          break 2
        fi
      done
    done
    if [[ -z "$matched_cidr" ]]; then
      report FAIL 'Resolved address is outside the discovered VPC CIDRs; the module VPC egress policy does not cover this target'
    else
      report INFO "Destination is within configured VPC CIDR $matched_cidr"
      if "${kube[@]}" exec "$pod_name" -c check -- timeout "${timeout}s" bash -c "exec 3<>\"/dev/tcp/\$1/\$2\"" _ "$matched_ip" "$tcp_port" >/dev/null 2>&1; then
        report PASS "TCP connection to $tcp_host:$tcp_port succeeded (connected to $matched_ip)"
        report INFO 'This confirms TCP reachability only; it does not test PostgreSQL/Redis protocol, TLS, or authentication'
      else
        report FAIL "TCP connection to $tcp_host:$tcp_port failed; check Calico policy, routing, security groups, and datastore health"
      fi
    fi
  fi
fi

if (( failed )); then
  exit 1
elif (( inconclusive )); then
  exit 2
fi