#!/usr/bin/env bash
#
# Host-side deploy helper for the EC2 target.
# Installed to /opt/app/deploy.sh by Terraform user data; CI invokes it through AWS SSM.
#
#   deploy.sh deploy   <image>     pull image, remember the current one, start the new one
#   deploy.sh smoke    [version]   poll /health (and check / reports <version>)
#   deploy.sh rollback             restart the previously running image
#   deploy.sh status               show what is running
#
set -euo pipefail

readonly STATE_DIR="/opt/app/state"
readonly ENV_FILE="/opt/app/app.env"
readonly CONTAINER="app"
# HOST_PORT / SMOKE_RETRIES may be set by app.env, so they are finalised in load_env()
# (marking them readonly here would make `source app.env` fail).

log() { printf '%s [deploy] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
  fi
  : "${AWS_REGION:?AWS_REGION must be set in $ENV_FILE}"
  : "${APP_ENV:?APP_ENV must be set in $ENV_FILE}"
  : "${LOG_GROUP:?LOG_GROUP must be set in $ENV_FILE}"
  HOST_PORT="${HOST_PORT:-80}"
  SMOKE_RETRIES="${SMOKE_RETRIES:-30}"
  readonly HOST_PORT SMOKE_RETRIES
  mkdir -p "$STATE_DIR"
}

registry_login() {
  local image="$1"
  local registry="${image%%/*}"
  if [[ "$registry" == *.dkr.ecr.*.amazonaws.com ]]; then
    # Credentials come from the EC2 instance profile - no static keys on the host.
    aws ecr get-login-password --region "$AWS_REGION" \
      | docker login --username AWS --password-stdin "$registry" >/dev/null
  fi
}

run_container() {
  local image="$1"
  local version="${image##*:}"

  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d \
    --name "$CONTAINER" \
    --restart unless-stopped \
    -p "${HOST_PORT}:8080" \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --memory 256m \
    --cpus 0.5 \
    -e APP_ENV="$APP_ENV" \
    -e LOG_LEVEL="${LOG_LEVEL:-INFO}" \
    -e APP_VERSION="$version" \
    --log-driver awslogs \
    --log-opt awslogs-region="$AWS_REGION" \
    --log-opt awslogs-group="$LOG_GROUP" \
    --log-opt awslogs-create-group=false \
    "$image" >/dev/null
  log "started $CONTAINER from $image"
}

cmd_deploy() {
  local image="${1:-}"
  [[ -n "$image" ]] || die "deploy requires an image reference"

  registry_login "$image"
  # Pull first: if the pull fails, the running container is never touched.
  docker pull --quiet "$image" >/dev/null
  log "pulled $image"

  local current=""
  [[ -f "$STATE_DIR/current" ]] && current="$(<"$STATE_DIR/current")"
  if [[ -n "$current" && "$current" != "$image" ]]; then
    printf '%s\n' "$current" >"$STATE_DIR/previous"
    log "recorded previous image: $current"
  fi

  run_container "$image"
  printf '%s\n' "$image" >"$STATE_DIR/current"
}

cmd_smoke() {
  local expected_version="${1:-}"
  local url="http://127.0.0.1:${HOST_PORT}"
  local i

  for ((i = 1; i <= SMOKE_RETRIES; i++)); do
    if curl -fsS --max-time 2 "$url/health" >/dev/null 2>&1; then
      if [[ -z "$expected_version" ]] \
        || curl -fsS --max-time 2 "$url/" | grep -q "\"version\":\"${expected_version}\""; then
        log "smoke test passed (attempt $i)"
        return 0
      fi
    fi
    sleep 2
  done
  log "smoke test FAILED after $SMOKE_RETRIES attempts"
  docker logs --tail 50 "$CONTAINER" 2>&1 || true
  return 1
}

cmd_rollback() {
  [[ -s "$STATE_DIR/previous" ]] || die "no previous image recorded; nothing to roll back to"
  local previous failed=""
  previous="$(<"$STATE_DIR/previous")"
  [[ -f "$STATE_DIR/current" ]] && failed="$(<"$STATE_DIR/current")"

  log "rolling back from ${failed:-<none>} to $previous"
  registry_login "$previous"
  run_container "$previous"
  printf '%s\n' "$previous" >"$STATE_DIR/current"
  [[ -n "$failed" ]] && printf '%s\n' "$failed" >"$STATE_DIR/failed"
  cmd_smoke "${previous##*:}"
}

cmd_status() {
  echo "current:  $(cat "$STATE_DIR/current" 2>/dev/null || echo '-')"
  echo "previous: $(cat "$STATE_DIR/previous" 2>/dev/null || echo '-')"
  docker ps --filter "name=^${CONTAINER}$" --format 'container: {{.Names}} {{.Image}} {{.Status}}'
}

main() {
  local action="${1:-}"
  shift || true
  case "$action" in
    deploy) load_env; cmd_deploy "$@" ;;
    smoke) load_env; cmd_smoke "$@" ;;
    rollback) load_env; cmd_rollback ;;
    status) load_env; cmd_status ;;
    -h | --help | help) usage ;;
    *) usage; exit 64 ;;
  esac
}

main "$@"
