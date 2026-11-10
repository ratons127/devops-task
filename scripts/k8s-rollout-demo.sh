#!/usr/bin/env bash
#
# Demonstrates a zero-downtime rolling update and a `kubectl rollout undo` on the kind cluster.
# A background probe hits the Ingress every 100ms during each rollout and records the HTTP
# status and the version that answered, so the switch-over (and any failures) is visible.
#
# Usage: scripts/k8s-rollout-demo.sh [new_version]   (default 1.0.1)
#
set -euo pipefail

readonly NS="devops-task"
readonly DEPLOY="deployment/devops-task-app"
readonly URL="${URL:-http://devops-task.localtest.me/}"
readonly NEW_VERSION="${1:-1.0.1}"
# Longer than the pod preStop sleep, so old pods have fully left the endpoints.
readonly SETTLE_SECONDS=10

probe() {
  # Appends "<http_code> <version>" per request to $1 until killed.
  local out="$1" body code version
  while true; do
    body="$(curl -s --max-time 2 -w ' %{http_code}' "$URL" || echo ' 000')"
    code="${body##* }"
    version="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' <<<"$body")"
    echo "${code} ${version:-none}" >>"$out"
    sleep 0.1
  done
}

watch_rollout() {
  local title="$1" change_cause="$2"
  shift 2
  local results probe_pid
  results="$(mktemp)"

  echo
  echo "=== ${title} ==="
  probe "$results" &
  probe_pid=$!
  sleep 1

  echo "\$ $*"
  "$@"
  if [[ -n "$change_cause" ]]; then
    # Annotate right after the change so it lands on the *new* ReplicaSet only.
    kubectl -n "$NS" annotate "$DEPLOY" "kubernetes.io/change-cause=${change_cause}" --overwrite >/dev/null
  fi
  echo "\$ kubectl -n ${NS} rollout status ${DEPLOY} --timeout=180s"
  kubectl -n "$NS" rollout status "$DEPLOY" --timeout=180s
  sleep "$SETTLE_SECONDS"

  kill "$probe_pid" 2>/dev/null || true
  wait "$probe_pid" 2>/dev/null || true

  local total failed
  total="$(wc -l <"$results" | tr -d ' ')"
  failed="$(grep -vc '^200 ' "$results" || true)"
  echo "Probe during rollout: ${total} requests, ${failed} non-200 responses"
  echo "Responses by status/version:"
  sort "$results" | uniq -c | sed 's/^/  /'
  echo "\$ curl -s ${URL}"
  curl -s "$URL"
  echo
  rm -f "$results"
}

echo "\$ kubectl -n ${NS} get pods -o wide"
kubectl -n "$NS" get pods -o wide

watch_rollout "Rolling update to ${NEW_VERSION}" "rolling update to ${NEW_VERSION}" \
  kubectl -n "$NS" set image "$DEPLOY" "app=devops-task-app:${NEW_VERSION}"

echo
echo "\$ kubectl -n ${NS} rollout history ${DEPLOY}"
kubectl -n "$NS" rollout history "$DEPLOY"

watch_rollout "Rollback with kubectl rollout undo" "" \
  kubectl -n "$NS" rollout undo "$DEPLOY"

echo
echo "\$ kubectl -n ${NS} rollout history ${DEPLOY}"
kubectl -n "$NS" rollout history "$DEPLOY"
echo "\$ kubectl -n ${NS} get pods"
kubectl -n "$NS" get pods
