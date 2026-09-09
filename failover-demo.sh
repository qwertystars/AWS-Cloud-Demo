#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"
yes=false
case "${1:-}" in
  '') [[ $# == 0 ]] || exit 2 ;;
  --yes) [[ $# == 1 ]] || exit 2; yes=true ;;
  *) echo 'Usage: ./failover-demo.sh [--yes]' >&2; exit 2 ;;
esac
load_outputs
wait_ready
printf '\nBefore stopping one task:\n'
"./status.sh"
read -r -a before <<< "$(running_tasks)"
((${#before[@]} >= 2)) || { echo 'Need at least two tasks.' >&2; exit 1; }
victim=${before[0]}
if [[ "$yes" == false ]]; then
  printf '\nStop exactly this task?\n%s\nType stop to confirm: ' "$victim"
  read -r confirmation
  [[ "$confirmation" == stop ]] || { echo 'Cancelled.'; exit 1; }
fi
# The ARN comes exclusively from this Terraform-managed service.
aws ecs stop-task --cluster "$CLUSTER" --task "$victim" \
  --reason 'Classroom self-healing demonstration' --query 'task.[taskArn,lastStatus]' --output table
printf '\nECS still desires the configured count. Watching the transient dip (it may be too brief to sample):\n'
for ((i=0; i<12; i++)); do
  printf 'Desired / running / pending: '; service_counts
  sleep 5
done
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$victim"
wait_ready
read -r -a after <<< "$(running_tasks)"
replacement=false
for task in "${after[@]}"; do
  [[ "$task" != "$victim" ]] || { echo 'Stopped task is unexpectedly still listed.' >&2; exit 1; }
  found=false
  for old in "${before[@]}"; do [[ "$task" != "$old" ]] || found=true; done
  if [[ "$found" == false ]]; then printf 'Replacement task: %s\n' "$task"; replacement=true; fi
done
[[ "$replacement" == true ]] || { echo 'No replacement task was observed.' >&2; exit 1; }
printf '\nRecovery complete: the desired number of tasks and healthy targets is restored.\n'
"./status.sh"
