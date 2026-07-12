variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "genai-on-eks"
}

# Public exposure is opt-in. When false, no CloudFront/WAF is created and the
# ALB stays internal-only (DyePack posture). Set true to expose litellm publicly.
variable "expose_litellm_public" {
  type    = bool
  default = false
}

# Cost-allocation tags — defaults mirror terraform/variables.tf so CloudFront/WAF
# resources carry the same Owner/CostCenter/Project/Environment as the rest of the estate.
variable "tag_owner" {
  type    = string
  default = "ml-platform-team"
}
variable "tag_cost_center" {
  type    = string
  default = "engineering"
}
variable "tag_project" {
  type    = string
  default = "flexAI"
}
variable "tag_environment" {
  type    = string
  default = "dev"
}
variable "tag_auto_delete" {
  type    = string
  default = "no"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.96.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Owner       = var.tag_owner
      CostCenter  = var.tag_cost_center
      Project     = var.tag_project
      Environment = var.tag_environment
      auto-delete = var.tag_auto_delete
      ManagedBy   = "terraform"
    }
  }
}

# --- Discover the live internal litellm ALB by the tags EKS Auto Mode sets ---
data "aws_lb" "litellm" {
  count = var.expose_litellm_public ? 1 : 0
  tags = {
    "eks:eks-cluster-name"               = var.name
    "ingress.eks.amazonaws.com/resource" = "LoadBalancer"
    "ingress.eks.amazonaws.com/stack"    = "litellm/litellm"
  }
}

# CloudFront's origin-facing edge IP ranges. VPC origin ENIs source from these,
# so the ALB SG must allow them (docs: "update the SG to allow the CloudFront
# managed prefix list"). us-east-1 name = com.amazonaws.global.cloudfront.origin-facing.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = var.expose_litellm_public ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

# ponytail: service-linked role AWSServiceRoleForCloudFrontVPCOrigin already
# exists in this account (verified). Creating it would fail on apply, so we don't.
# If you deploy to a fresh account, run once:
#   aws iam create-service-linked-role --aws-service-name vpcorigin.cloudfront.amazonaws.com

# ponytail: the ALB security-group ingress from CloudFront is owned by the litellm
# ingress annotation (alb.ingress.kubernetes.io/security-group-prefix-lists), not
# by a Terraform aws_security_group_rule — the ALB SG is controller-managed, so a
# TF-authored rule on it would be reconciled away. We only expose the prefix-list
# ID as an output for the ingress to consume.

# =====================================================================
# WAF — CLOUDFRONT scope must live in us-east-1 (provider is us-east-1)
# =====================================================================
resource "aws_wafv2_web_acl" "litellm" {
  count = var.expose_litellm_public ? 1 : 0
  name  = "${var.name}-litellm-edge"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # AWS baseline: common OWASP-ish protections.
  rule {
    name     = "common-rules"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-litellm-common"
      sampled_requests_enabled   = true
    }
  }

  # Known bad inputs (log4j, path traversal, etc.)
  rule {
    name     = "known-bad-inputs"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-litellm-badinputs"
      sampled_requests_enabled   = true
    }
  }

  # Per-IP rate limit — the only brute-force guard on the virtual-key auth.
  rule {
    name     = "rate-limit"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-litellm-rate"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-litellm-edge"
    sampled_requests_enabled   = true
  }
}

# =====================================================================
# CloudFront VPC origin -> internal ALB (ALB listens HTTP:80)
# =====================================================================
resource "aws_cloudfront_vpc_origin" "litellm" {
  count = var.expose_litellm_public ? 1 : 0
  vpc_origin_endpoint_config {
    name                   = "${var.name}-litellm"
    arn                    = data.aws_lb.litellm[0].arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

# API traffic: never cache, forward everything.
resource "aws_cloudfront_cache_policy" "no_cache" {
  count       = var.expose_litellm_public ? 1 : 0
  name        = "${var.name}-no-cache"
  default_ttl = 0
  max_ttl     = 0
  min_ttl     = 0
  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    enable_accept_encoding_brotli = false
    enable_accept_encoding_gzip   = false
  }
}

resource "aws_cloudfront_origin_request_policy" "forward_all" {
  count = var.expose_litellm_public ? 1 : 0
  name  = "${var.name}-forward-all"
  cookies_config {
    cookie_behavior = "all"
  }
  headers_config {
    header_behavior = "allViewer"
  }
  query_strings_config {
    query_string_behavior = "all"
  }
}

resource "aws_cloudfront_distribution" "litellm" {
  count           = var.expose_litellm_public ? 1 : 0
  enabled         = true
  comment         = "${var.name} litellm public edge (WAF-fronted, VPC origin)"
  web_acl_id      = aws_wafv2_web_acl.litellm[0].arn
  is_ipv6_enabled = true
  # Regional price class is enough for an internal tool; widen if callers are global.
  price_class = "PriceClass_100"

  origin {
    origin_id   = "litellm-alb"
    domain_name = data.aws_lb.litellm[0].dns_name

    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.litellm[0].id
    }
  }

  default_cache_behavior {
    target_origin_id       = "litellm-alb"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    cache_policy_id          = aws_cloudfront_cache_policy.no_cache[0].id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.forward_all[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "litellm_cloudfront_url" {
  value = var.expose_litellm_public ? "https://${aws_cloudfront_distribution.litellm[0].domain_name}" : ""
}

# Consumed by the litellm ingress security-group-prefix-lists annotation to lock
# the ALB to CloudFront edge IPs at L3/L4.
output "cloudfront_prefix_list_id" {
  value = var.expose_litellm_public ? data.aws_ec2_managed_prefix_list.cloudfront[0].id : ""
}
