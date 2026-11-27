# The insecure example's configuration (no request signing) with CloudFront and monitoring on at the
# same time. The other test files cover each feature alone; this one guards the combination, and is
# also run against the oldest and newest supported AWS provider in CI.
mock_provider "aws" {}

variables {
  vpc_id     = "vpc-12345678"
  subnet_ids = ["subnet-aaa111", "subnet-bbb222"]

  insecure            = true
  allow_insecure_http = true
  enable_cloudfront   = true
  enable_monitoring   = true
}

run "insecure_with_cloudfront_and_monitoring" {
  command = plan

  assert {
    condition     = module.aws_common.cloudfront_created == true
    error_message = "CloudFront must be created when enable_cloudfront = true"
  }

  assert {
    condition     = length([for c in jsondecode(aws_ecs_task_definition.main.container_definitions) : c if c.name == "otel-collector"]) == 1
    error_message = "OTEL sidecar container must be present when enable_monitoring = true"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_ecs_task_definition.main.container_definitions)[0].secrets : s
      if s.name == "IMGPROXY_KEY" || s.name == "IMGPROXY_SALT"
    ]) == 0
    error_message = "No signing secrets should be wired when insecure = true"
  }
}
