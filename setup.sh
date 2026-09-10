#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"
[[ $# == 0 ]] || { echo 'Usage: ./setup.sh (Terraform asks for apply confirmation)' >&2; exit 2; }
require_commands terraform aws curl
require_python
trap 'echo "Setup failed; resources may still exist. Inspect ./status.sh, then retry setup or run ./destroy.sh. Nothing was automatically destroyed." >&2' ERR
terraform init -input=false
terraform fmt -check -recursive
terraform validate
REGION=$(configured_region)
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"
identity
# A saved plan guarantees the approved actions are the actions applied. The
# template keeps its placeholders last for BSD mktemp, and the file stays in the
# project directory so Terraform receives a path every platform resolves.
plan_file=$(mktemp ./aws-class-demo-plan-XXXXXX)
trap 'rm -f -- "$plan_file"' EXIT
terraform plan -input=false -out="$plan_file"
printf '\nThis plan creates billable AWS resources. Type apply to apply this exact plan: '
read -r confirmation
[[ "$confirmation" == apply ]] || { echo 'Cancelled; no plan applied.'; exit 1; }
terraform apply -input=false "$plan_file"
load_outputs
wait_ready
printf '\nDEMO READY: %s\nCluster: %s\nService: %s\n' "$URL" "$CLUSTER" "$SERVICE"
printf 'Desired / running / pending: '; service_counts
printf '\nAfter class, run ./destroy.sh to stop charges.\n'
