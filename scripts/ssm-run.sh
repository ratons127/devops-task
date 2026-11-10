#!/usr/bin/env bash
#
# Run a shell command on the EC2 instance of an environment via AWS SSM Run Command,
# wait for it to finish, print its output and exit with its status.
#
# Usage: ssm-run.sh <environment> <command string>
# Example: ssm-run.sh staging "/opt/app/deploy.sh status"
#
# Requires: aws CLI v2, jq, and AWS credentials (in CI: GitHub OIDC role).
#
set -euo pipefail

readonly PROJECT_TAG="${PROJECT_TAG:-devops-task}"
readonly TIMEOUT_SECONDS="${SSM_TIMEOUT_SECONDS:-300}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <environment> <command>"
env_name="$1"
command="$2"

instance_id="$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
            "Name=tag:Environment,Values=${env_name}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"

[[ -n "$instance_id" && "$instance_id" != "None" ]] || die "no running instance for env '${env_name}'"
[[ "$instance_id" != *[[:space:]]* ]] || die "expected exactly one instance, got: ${instance_id}"

params="$(jq -nc --arg c "$command" '{commands: [$c]}')"
command_id="$(aws ssm send-command \
  --instance-ids "$instance_id" \
  --document-name "AWS-RunShellScript" \
  --comment "github-actions ${GITHUB_RUN_ID:-manual}" \
  --parameters "$params" \
  --query 'Command.CommandId' --output text)"

echo "SSM command ${command_id} sent to ${instance_id}: ${command}"

status="Pending"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while [[ "$status" =~ ^(Pending|InProgress|Delayed)$ ]]; do
  (( SECONDS < deadline )) || die "timed out after ${TIMEOUT_SECONDS}s waiting for ${command_id}"
  sleep 5
  status="$(aws ssm get-command-invocation \
    --command-id "$command_id" --instance-id "$instance_id" \
    --query 'Status' --output text 2>/dev/null || echo Pending)"
done

echo "----- stdout -----"
aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
  --query 'StandardOutputContent' --output text
echo "----- stderr -----"
aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
  --query 'StandardErrorContent' --output text
echo "------------------"
echo "SSM status: ${status}"

[[ "$status" == "Success" ]]
