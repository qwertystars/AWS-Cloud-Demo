# AWS-Cloud-Demo

A short classroom demo of ECS Fargate, load balancing, and self-healing in **ap-south-1**. Two small Apache containers show their own hostnames on a web page. No Kubernetes, EC2 instances to maintain, NAT Gateway, or database.

**Cleanup is mandatory: run `./destroy.sh` after class. Closing the terminal does not stop billing.** ALB, Fargate compute, public IPv4 addresses, and data transfer can incur charges until resources are destroyed. This is not a free-tier guarantee. Failed setup can also leave billable resources.

## Rehearse locally with Docker

A complete [local Docker demo](local/README.md) runs two Apache backends behind HAProxy, with a health dashboard, automatic process restart, explicit container replacement, and cleanup. No AWS credentials are needed.

```bash
./local/demo.sh setup
./local/demo.sh status
./local/demo.sh demo
./local/demo.sh self-heal
./local/demo.sh destroy
```

Application: **http://127.0.0.1:8080**. Health dashboard: **http://127.0.0.1:8404**. Compose restart behavior differs from ECS replacement; the local guide explains what each demonstration proves. Local cleanup does not destroy any AWS deployment.

## Prerequisites

- Terraform **1.13–1.16** (validated with 1.15.9), AWS CLI v2, Bash, curl, Python 3, and standard Unix tools. Run scripts in Bash on Linux, macOS, or WSL.
- AWS credentials configured, for example with `aws configure` or AWS SSO (`aws sso login --profile classroom`, then `export AWS_PROFILE=classroom`). Never put credentials in this repository.
- A default VPC with two public subnets in distinct standard Availability Zones, each /27 or larger with at least 12 free IPs and an Internet Gateway default route. Terraform checks effective route tables, including the main table. It does not alter the shared network. Default network ACLs, DNS, and the Internet Gateway must be functional; customized ACL restrictions may prevent traffic or image pulls.
- Sufficient Fargate vCPU, ALB, and public IPv4 quotas. During deployment ECS may temporarily run up to four tasks at the default desired count.
- Deployment identity permissions to read VPCs, subnets, routes, AZs and caller identity; create/read/update/delete ECS clusters, task definitions and services, ELBv2 ALBs/listeners/target groups, security groups and their rules, and the project's IAM execution role/policy attachment; tag these resources; and `iam:PassRole` for that execution role. The first ECS/ELB deployment in an account may need `iam:CreateServiceLinkedRole`. Self-healing also needs `ecs:StopTask`; status requires ECS/ELB describe/list operations. Use an instructor-approved account and policy. The application has no task IAM role; its execution role receives only `AmazonECSTaskExecutionRolePolicy`.

AWS account-level ECS/ELB service-linked roles may be created automatically by AWS and are shared account infrastructure. Terraform does not delete those roles or the existing default VPC/subnets. They do not themselves incur hourly compute charges.

## Commands

```bash
./setup.sh
./status.sh
./demo.sh
./failover-demo.sh
./destroy.sh
```

`setup.sh` initializes Terraform, checks formatting and validity, prints the account/region/workspace, and makes a saved plan. It requires typing **apply** before applying that exact plan. It waits for ECS stability, the desired number of healthy targets, and a successful HTTP response. Allow roughly 5–15 minutes; network/image-pull problems can take longer or time out. It prints the final URL, cluster, service, and task counts.

`demo.sh` makes 20 requests with separate connections and displays backend hostnames plus counts. Multiple hostnames demonstrate distribution. Request order and equal request counts are not guaranteed; this is not a strict round-robin demonstration. If only one backend appears, it prints a warning: check target health and rerun.

`status.sh` shows desired/running/pending counts, task ARNs (the final ARN segment is the task ID), task status, target IPs/health, ALB DNS, URL, and recent service events. Container health may say UNKNOWN because readiness is assessed by the ALB health check, not a container health command.

`failover-demo.sh` first verifies readiness, then requires typing **stop** before stopping exactly one task from this service. It polls counts, waits for the old task to stop, identifies a new task ARN, and verifies stability and healthy targets again. ECS keeps desiring two tasks; a temporary running-count dip can be too brief to sample. The task ARN change is evidence of replacement. Some in-flight requests may fail while a task stops; this demo does not promise zero downtime. Use `./failover-demo.sh --yes` to explicitly skip the prompt.

`destroy.sh` prints the current AWS account, region, workspace, and resources; checks that account against recorded outputs/resource ARNs; and requires typing **destroy**. `./destroy.sh --yes` skips the prompt. It runs Terraform destroy and checks that no managed resource instances remain in state. Errors exit nonzero and warn that cleanup may be incomplete.

## Configuration

Defaults: prefix `aws-class-demo`, two tasks, 256 CPU units (0.25 vCPU) and 512 MiB per task. The official HashiCorp AWS provider is constrained to 6.x; the included `.terraform.lock.hcl` pins the validated version 6.63.0. Commit this lock file so subsequent installs use the same version.

Optional settings go in a local, ignored `terraform.tfvars`:

```hcl
region         = "ap-south-1"
project_prefix = "aws-class-demo"
desired_count  = 2
task_cpu       = 256
task_memory    = 512
```

Keep these settings, AWS profile, workspace, and local state unchanged until cleanup. Use a unique prefix per independently deployed classroom demo; IAM role names are account-wide. The helpers resolve region from Terraform configuration for setup and recorded outputs for status. Do not change the configured region before destroying; the destroy helper rejects a mismatch with the recorded region because the provider uses the configuration during destroy. Avoid `TF_CLI_ARGS*` overrides, provider credential overrides, or backend changes when using these helpers.

The `httpd:2.4` public ECR image is intentionally easy to understand but is a mutable tag; rehearse before class. Its startup command writes `hostname` into the page and then starts Apache in the foreground. No image build or registry login is needed. Tasks have public IPv4 for pulling the image; their port 80 accepts traffic **only from the ALB security group**. This is a public HTTP demonstration: do not send sensitive data.

## Architecture and classroom vocabulary

```text
Internet -> ALB :80 -> Target group (IP targets, HTTP / health check)
                         |                    |
                    Fargate task 1       Fargate task 2
                         +---- ECS service ---+
                                  |
                             ECS cluster
```

| Component | Meaning |
| --- | --- |
| ECS Cluster | A logical place to group the application's services and tasks. |
| Task Definition | The recipe: image, startup command, CPU, memory and port. |
| Task | One running copy of that recipe, with its own container hostname and network interface. |
| Service | Keeps the desired number of tasks running and replaces stopped tasks. |
| Target Group | The list of task IP addresses that the load balancer can send requests to. ECS maintains membership. |
| Application Load Balancer | The public HTTP entry point that distributes requests to healthy targets. |
| Health Check | The ALB requests `/` every 15 seconds and expects HTTP 200; repeated failures mark a target unhealthy. |
| Fargate | AWS runs the containers without requiring you to manage servers. |

The service keeps 100% healthy capacity during deployments and permits up to 200% while replacing tasks. A deployment circuit breaker helps stop failed deployments. No costly observability stack is added; recent ECS events and stopped-task details help diagnose failures.

Subnet selection follows [AWS ALB subnet guidance](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/application-load-balancers.html), with extra free-IP headroom for demo tasks. Service configuration uses the [official Terraform AWS ECS service resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service).

## Recommended live flow

1. Run `./setup.sh`, review the account and plan, and type `apply`.
2. Open ECS in the AWS Console in the selected region, then open the output cluster.
3. Show the service desiring two tasks and two tasks running.
4. Open EC2 → Load Balancers, show the ALB and HTTP listener, and open its URL.
5. Open Target Groups → Targets and show two healthy IP targets.
6. Run `./demo.sh` to observe different container hostnames.
7. Optionally run `./failover-demo.sh`; show the unchanged desired count and replacement task.
8. **Run `./destroy.sh` and wait for the cleanup success message before leaving.**

## Cleanup and recovery

```bash
./destroy.sh
# For an explicitly unattended cleanup:
./destroy.sh --yes
```

**Keep `terraform.tfstate` and its backup until cleanup succeeds.** State maps this project to its AWS resources. Never delete state as a way to clean up. The destroy script removes only resources managed by the selected Terraform workspace; it never searches for and deletes unrelated resources. Empty state cannot prove that resources whose state was lost or manually removed are gone. Do not use this directory's state to manage unrelated infrastructure.

A failed setup does not automatically destroy infrastructure. Run `./status.sh` if outputs exist; otherwise use `terraform state list` and the AWS Console to inspect partial deployment. Resolve the issue and rerun `./setup.sh`, or run `./destroy.sh` with the same configuration and credentials. On failed cleanup, retain state, fix credentials/permissions or dependencies, and rerun destroy. Shared VPC/subnets and account-level service-linked roles remain intentionally.

Common issues: missing default VPC/two usable AZs (ask the instructor to repair the default network), task image-pull errors (public route, DNS, network ACLs, public IP and public ECR availability), insufficient Fargate quota, or IAM permission errors. Recent ECS service events are printed by `status.sh`; inspect stopped tasks in the Console for startup errors. ALB DNS and health propagation can take a few minutes. A missed readiness deadline is a failure, never an automatic declaration of success.

## Local verification without creating resources

```bash
terraform fmt -recursive
terraform init -input=false
terraform validate
terraform test
python3 -m unittest discover -s tests -v
for script in setup.sh status.sh demo.sh failover-demo.sh destroy.sh scripts/common.sh; do
  bash -n "$script"
done
```

These commands do not create AWS infrastructure. Terraform tests use a mocked AWS provider; Python tests use fake CLI executables to check distribution, readiness, self-healing, and cleanup safety. `terraform plan` reads AWS and needs credentials. `./setup.sh` only creates resources after explicit confirmation. Local validation cannot prove live image pulling, networking, or failover: rehearse the full flow in your authorized account, then destroy it.
