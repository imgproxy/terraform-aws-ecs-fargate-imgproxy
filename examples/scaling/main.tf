terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "AWS CLI profile used by the provider (null = default credentials / AWS_PROFILE)"
  type        = string
  default     = null
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

# The default VPC only has public subnets, so this example runs in it to stay self-contained.
# For production, use your own VPC with private subnets and HTTPS: see "Production setup" in the
# README and the commented-out settings in the module block below.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_secretsmanager_secret" "keys" {
  name = "imgproxy-keys"
}

data "aws_secretsmanager_secret" "salts" {
  name = "imgproxy-salts"
}

module "imgproxy" {
  source  = "imgproxy/ecs-fargate-imgproxy/aws"
  version = "~> 0.1"

  service_name = "imgproxy"
  tag          = "v4"

  # Request signing (required for production)
  keys_secret = {
    arn = data.aws_secretsmanager_secret.keys.arn
  }
  salts_secret = {
    arn = data.aws_secretsmanager_secret.salts.arn
  }

  # Task size. Fargate accepts only certain cpu/memory pairs: 1 vCPU takes 2-8 GB.
  cpu              = 1
  memory           = "2048Mi"
  cpu_architecture = "ARM64" # Graviton: cheaper, same performance. "X86_64" needs an x86 image
  workers          = 2       # concurrent requests per task (default: cpu x 2)

  # Task count. Application Auto Scaling adds and removes tasks between these bounds, based on
  # imgproxy's WorkersUtilization metric (out above 80%, in below 50%).
  task_min_count = 2
  task_max_count = 10
  # desired_count = 2 # only the initial count (default: task_min_count); autoscaling owns it afterwards

  # Fargate Spot: 70% of the tasks run on Spot capacity (up to 70% cheaper). One task always
  # stays on regular Fargate, and imgproxy is stateless, so an interrupted task is replaced.
  spot_percentage = 70

  # Rolling deployments and scale-in
  deployment_minimum_healthy_percent = 100 # start a new task before stopping an old one
  alb_idle_timeout                   = 60
  alb_deregistration_delay           = 300 # must be >= alb_idle_timeout

  # Networking: tasks in public subnets of the default VPC
  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids

  # Testing opt-ins: the module is private and encrypted by default. The default VPC has only public
  # subnets and this example has no domain, so both defaults are waived here. For production, drop
  # them and use the settings below.
  assign_public_ip    = true # tasks in public subnets need a public IP to pull the image
  allow_insecure_http = true # plain HTTP on the ALB: requests and signed URLs are unencrypted

  # Production: tasks in private subnets, only the load balancer public, HTTPS on the load balancer.
  # The private subnets need a route to a NAT gateway; see "Production setup" in the README.
  # vpc_id               = "vpc-0123456789abcdef0"
  # subnet_ids           = ["subnet-0aaa...", "subnet-0bbb..."] # private: the tasks
  # alb_subnet_ids       = ["subnet-0ccc...", "subnet-0ddd..."] # public: the internet-facing ALB
  # alb_certificate_arns = ["arn:aws:acm:us-east-1:123456789012:certificate/..."]
}

output "url" {
  value = module.imgproxy.url
}

output "alb_dns_name" {
  value       = module.imgproxy.alb_dns_name
  description = "ALB DNS name. Point your domain at it when you attach a certificate"
}

output "alb_zone_id" {
  value       = module.imgproxy.alb_zone_id
  description = "ALB hosted zone ID, for Route 53 alias records"
}
