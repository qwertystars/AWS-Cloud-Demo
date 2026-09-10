#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"
[[ $# == 0 ]] || { echo 'Usage: ./status.sh' >&2; exit 2; }
load_outputs
printf '\nCluster: %s\nService: %s\nALB DNS: %s\nDemo URL: %s\n\n' "$CLUSTER" "$SERVICE" "$(terraform_output load_balancer_dns)" "$URL"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[].{Service:serviceName,Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount}' --output table
read -r -a tasks <<< "$(running_tasks)"
if ((${#tasks[@]})); then
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks "${tasks[@]}" \
    --query 'tasks[].{Task:taskArn,Status:lastStatus,Desired:desiredStatus,Health:healthStatus}' --output table
else
  echo 'No running or starting tasks.'
fi
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].{IP:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}' --output table
printf '\nRecent ECS events:\n'
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].events[:5].[createdAt,message]' --output table
