#!/usr/bin/env bash
# Shared helpers. Entry points enable strict mode before sourcing this file.
# Portable to Linux, macOS (Bash 3.2 and BSD userland) and Windows Git Bash.
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

# The AWS CLI is a Python program, so on Windows it writes CRLF line endings.
# Removing CR keeps comparisons, `read` and arithmetic identical everywhere.
aws() { command aws "$@" | tr -d '\r'; }

terraform_output() { terraform output -raw "$1" | tr -d '\r'; }

require_commands() {
  local command_name
  for command_name in "$@"; do
    # type -P searches only PATH, so the aws wrapper above cannot disguise a
    # missing AWS CLI as a satisfied requirement.
    type -P "$command_name" >/dev/null || { echo "Missing required command: $command_name" >&2; exit 1; }
  done
}

# Windows installs Python as `python` or the `py` launcher, and the Microsoft
# Store ships a `python3` stub that is not an interpreter, so probe candidates.
PYTHON=""
require_python() {
  local candidate
  [[ -z "$PYTHON" ]] || return 0
  for candidate in python3 python py; do
    type -P "$candidate" >/dev/null || continue
    "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3,) else 1)' >/dev/null 2>&1 || continue
    PYTHON=$candidate
    return 0
  done
  echo 'Missing required command: python3' >&2
  exit 1
}

configured_region() {
  terraform console <<< 'var.region' | tr -d '"\r'
}

identity() {
  local expected account
  require_python
  account=$(aws sts get-caller-identity --region "$REGION" --query Account --output text)
  printf 'AWS account: %s\nAWS region:  %s\nWorkspace:   %s\n' "$account" "$REGION" "$(terraform workspace show | tr -d '\r')"
  expected=$(terraform_output account_id 2>/dev/null || true)
  if [[ -n "$expected" && "$account" != "$expected" ]]; then
    echo "Refusing: credentials do not match the account recorded in Terraform outputs." >&2
    exit 1
  fi
  # Also handles partial applies that have resource ARNs but no outputs yet.
  if terraform state list > /dev/null 2>&1; then
    terraform state pull | "$PYTHON" -c '
import json, re, sys
state = json.load(sys.stdin)
accounts = set()
def visit(value):
    if isinstance(value, dict):
        for v in value.values(): visit(v)
    elif isinstance(value, list):
        for v in value: visit(v)
    elif isinstance(value, str):
        m = re.match(r"arn:[^:]+:[^:]+:[^:]*:(\d{12}):", value)
        if m: accounts.add(m[1])
for resource in state.get("resources", []):
    if resource.get("mode") == "managed": visit(resource.get("instances", []))
if accounts - {sys.argv[1]}:
    sys.exit("Refusing: managed resource ARNs belong to another AWS account.")
' "$account"
  fi
}

load_outputs() {
  require_commands terraform aws curl
  require_python
  REGION=$(terraform_output region)
  export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"
  CLUSTER=$(terraform_output cluster_name)
  SERVICE=$(terraform_output service_name)
  TG=$(terraform_output target_group_arn)
  URL=$(terraform_output demo_url)
  identity
}

service_counts() {
  aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text
}

running_tasks() {
  aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
    --desired-status RUNNING --query taskArns --output text
}

wait_ready() {
  echo 'Waiting for ECS service stability (up to approximately 10 minutes)...'
  aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
  local attempt desired running pending healthy total
  for ((attempt=1; attempt<=60; attempt++)); do
    read -r desired running pending <<< "$(service_counts)"
    healthy=$(aws elbv2 describe-target-health --target-group-arn "$TG" \
      --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
    total=$(aws elbv2 describe-target-health --target-group-arn "$TG" \
      --query 'length(TargetHealthDescriptions)' --output text)
    printf 'Desired=%s Running=%s Pending=%s Healthy targets=%s Total targets=%s\n' "$desired" "$running" "$pending" "$healthy" "$total"
    if [[ "$desired" =~ ^[0-9]+$ && "$desired" -ge 2 && "$running" == "$desired" && "$pending" == 0 && "$healthy" == "$desired" && "$total" == "$desired" ]]; then
      if curl --fail --silent --show-error --connect-timeout 5 --max-time 10 "$URL" >/dev/null; then
        return 0
      fi
    fi
    sleep 5
  done
  echo 'Readiness timed out. Run ./status.sh and inspect ECS service events.' >&2
  return 1
}
