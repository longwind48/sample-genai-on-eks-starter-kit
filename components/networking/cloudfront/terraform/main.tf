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

  # LLM request bodies are large. Raise WAF body inspection from the 16KB default
  # to the 64KB max so managed rules see the whole body; combined with the
  # SizeRestrictions_BODY Count override below, oversized bodies pass instead of
  # returning the CloudFront edge 403 that broke Claude Code/Cowork.
  association_config {
    request_body {
      cloudfront {
        default_size_inspection_limit = "KB_64"
      }
    }
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

        # The common rule set inspects the request body, but WAF can inspect at
        # most 64KB and Claude Code/Cowork bodies (history + tool schemas + files)
        # exceed that — so body rules block legitimate LLM traffic outright.
        # Scope-down: only evaluate the common rules on requests whose path is
        # NOT under /v1/ (the LLM API surface). The UI and everything else still
        # get full common-rule protection. /v1/* is still covered by the
        # known-bad-inputs group (headers/URI) + the per-IP rate limit below.
        scope_down_statement {
          not_statement {
            statement {
              byte_match_statement {
                search_string         = "/v1/"
                positional_constraint = "STARTS_WITH"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }

        # Belt-and-suspenders for any /v1-adjacent path that still matches: don't
        # let the body-size / LFI-body rules block large legitimate payloads.
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
        rule_action_override {
          name = "GenericLFI_BODY"
          action_to_use {
            count {}
          }
        }
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

        # Same reasoning as the common set: this group also inspects the body
        # (Log4JRCE_BODY etc.) and hits the 64KB wall on large LLM payloads.
        # Only evaluate on non-/v1/ paths; /v1/* stays protected by the rate
        # limit and by LiteLLM's own virtual-key auth.
        scope_down_statement {
          not_statement {
            statement {
              byte_match_statement {
                search_string         = "/v1/"
                positional_constraint = "STARTS_WITH"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
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
      # LLM turns routinely exceed the 30s default (measured ~27s for 2000 tokens).
      # 60s is the max without an origin-response-timeout quota increase; request
      # a quota bump for up to 180s if long reasoning turns still time out.
      origin_read_timeout = 60
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
