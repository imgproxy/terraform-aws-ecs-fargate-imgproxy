# Scaling

Signed imgproxy with every resource and scaling setting spelled out: task size, task count, Fargate Spot and
rolling deployments. Settings that do not apply are left commented in `main.tf`.

## AWS setup

You need an AWS account and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated:

```bash
aws configure
# or: aws sso login --profile my-profile && export AWS_PROFILE=my-profile
```

> The `aws` commands below use two profiles, set at the start of Prerequisites: `PROFILE_NAME` is the one Terraform uses, and `ADMIN_PROFILE_NAME` creates, reads and deletes the Secrets Manager secrets and the S3 buckets. They may be the same or different; drop the flags if you use the default credentials.
> `ADMIN_PROFILE_NAME` must be allowed `secretsmanager:CreateSecret`, `GetSecretValue` and `DeleteSecret`, or `aws secretsmanager create-secret` fails with `AccessDeniedException`. `PROFILE_NAME` does not need them: Terraform only looks the secrets up (`DescribeSecret`, `GetResourcePolicy`).
> An `aws: [ERROR]: An error occurred (ForbiddenException) when calling the GetRoleCredentials operation: No access` error usually means the profile is missing or wrong.

## Prerequisites

Create the signing keys and store them in Secrets Manager:

```bash
PROFILE_NAME=my-profile # AWS CLI profile used by Terraform; see AWS setup
ADMIN_PROFILE_NAME=$PROFILE_NAME # profile that creates the secrets and buckets; may differ, see AWS setup
REGION=us-east-1

aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-keys --secret-string "$(openssl rand -hex 64)"
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-salts --secret-string "$(openssl rand -hex 64)"
```

## Deploy

```bash
echo "region = \"$REGION\"" > terraform.tfvars
echo "profile = \"$PROFILE_NAME\"" >> terraform.tfvars # AWS CLI profile used by Terraform; omit for default credentials

terraform init
terraform plan
terraform apply

# Unsigned requests are rejected (give the tasks a couple of minutes to become healthy first)
curl -I "$(terraform output -raw url)/insecure/plain/https://picsum.photos/200"   # 403 Forbidden
```

Print a signed URL (paste it into a browser):

```bash
(
URL=$(terraform output -raw url)
KEY=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --query SecretString --output text)
SALT=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --query SecretString --output text)
IMG_PATH="/rs:fit:300:300/plain/https://picsum.photos/1200/800.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

This assumes a single key/salt pair. See [imgproxy's signing algorithm](https://docs.imgproxy.net/usage/signing_the_url) for details.

## Scaling variables

- **Task size**: `cpu` and `memory` must be a pair Fargate supports (1 vCPU takes 2-8 GB). `workers` is the number of
  concurrent requests per task and defaults to `cpu` x 2. `cpu_architecture` is `ARM64` (Graviton, cheaper) or
  `X86_64`; it must match the image.
- **Task count**: `task_min_count` and `task_max_count` bound Application Auto Scaling, which adds tasks when
  imgproxy's `WorkersUtilization` metric is above 80% and removes them below 50%. `desired_count` only sets the
  initial count; ECS owns it afterwards.
- **Spot**: `spot_percentage` runs that share of tasks on Fargate Spot. Interrupted tasks are replaced, which suits
  stateless imgproxy.
- **Deployments and scale-in**: `deployment_minimum_healthy_percent = 100` starts a new task before stopping an old one.
  `alb_deregistration_delay` (drain time) must be at least `alb_idle_timeout`.

## Production setup

This example runs in the default VPC and serves plain HTTP, so it waives two of the module's secure defaults
explicitly (`assign_public_ip = true` and `allow_insecure_http = true`). That is only meant for trying the module out:
unsigned traffic and signed URLs cross the network unencrypted. **In production, drop both opt-ins**, run the tasks in
private subnets, keep only the load balancer public, and serve it over HTTPS.

### Private subnets

```hcl
vpc_id         = "vpc-0123456789abcdef0"
subnet_ids     = ["subnet-0aaa...", "subnet-0bbb..."] # private subnets: the tasks
alb_subnet_ids = ["subnet-0ccc...", "subnet-0ddd..."] # public subnets: the internet-facing ALB
# assign_public_ip is false by default
```

- Set `alb_subnet_ids` to public subnets. If you leave it unset, the ALB is placed in `subnet_ids`, that is, in the
  private subnets, and is not reachable from the internet. For an ALB reachable only from inside the VPC, use
  `internal_alb = true` instead.
- With no public IPs, the tasks need an outbound route. imgproxy downloads source images from the internet and the
  task pulls its image from `ghcr.io` (or `docker.imgproxy.pro`), so the private subnets need a **NAT gateway**. Without
  one, tasks fail to start with `CannotPullContainerError`.
- If your source images only live in S3 and the image comes from ECR, you can skip the NAT gateway and use VPC
  endpoints instead: an S3 gateway endpoint (free) plus interface endpoints for `ecr.api`, `ecr.dkr`,
  `secretsmanager` and `logs`.
- The task security group only accepts traffic on port 8080 from the ALB, so private tasks are not reachable from
  anywhere else. Add rules for VPN or bastion access through the `tasks_security_group_id` output.

### HTTPS

Request an ACM certificate for your domain in the same region, attach it, and point a DNS record for the domain at
the load balancer (`terraform output alb_dns_name`, or a Route 53 alias with `alb_zone_id`):

```hcl
alb_certificate_arns = ["arn:aws:acm:us-east-1:123456789012:certificate/..."]
```

With a certificate, plain HTTP requests are redirected to HTTPS (`alb_redirect_http_to_https`) and `allow_insecure_http`
is no longer needed. Without one the module refuses to plan unless you set `allow_insecure_http = true`.

The other examples keep using the default VPC and plain HTTP for brevity; the same settings apply to all of them.

## Cleanup

```bash
terraform destroy
```

The secrets created in Prerequisites are not managed by Terraform; delete them separately:

```bash
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --force-delete-without-recovery
```

## Next

Continue with [s3](../s3/).
