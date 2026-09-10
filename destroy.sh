#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"
yes=false
case "${1:-}" in
  '') [[ $# == 0 ]] || exit 2 ;;
  --yes) [[ $# == 1 ]] || exit 2; yes=true ;;
  *) echo 'Usage: ./destroy.sh [--yes]' >&2; exit 2 ;;
esac
require_commands terraform aws
require_python
trap 'echo "WARNING: cleanup is incomplete or could not be verified. Resources may still incur charges. Keep the state, resolve the error, and rerun ./destroy.sh." >&2' ERR
terraform init -input=false
REGION=$(terraform_output region 2>/dev/null || configured_region)
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"
identity
configured=$(configured_region)
[[ "$configured" == "$REGION" ]] || {
  echo "Refusing: configured region $configured differs from recorded region $REGION. Restore the original configuration before cleanup." >&2
  exit 1
}
printf '\nTerraform resources in the current workspace:\n'
terraform state list
if [[ "$yes" == false ]]; then
  printf '\nDestroy this Terraform project in the account above? Type destroy to confirm: '
  read -r confirmation
  [[ "$confirmation" == destroy ]] || { echo 'Cancelled; resources remain running.'; exit 1; }
fi
# Explicit confirmation above, or --yes, authorizes Terraform auto-approval.
terraform destroy -input=false -auto-approve
terraform state pull | "$PYTHON" -c '
import json, sys
state = json.load(sys.stdin)
remaining = [r["type"] + "." + r["name"] for r in state.get("resources", [])
             if r.get("mode") == "managed" and r.get("instances")]
if remaining:
    sys.exit("WARNING: managed resources remain: " + ", ".join(remaining))
print("Cleanup successful: Terraform state contains no managed resources. ALB and Fargate resources managed by this project have been destroyed.")
'
