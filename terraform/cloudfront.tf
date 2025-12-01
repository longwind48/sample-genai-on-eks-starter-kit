# CloudFront distributions for GenAI services
# Creates a separate CloudFront distribution per service for proper HTTPS access
# Only created when domain is empty (no custom domain setup)

locals {
  enable_cloudfront = var.domain == ""
}

# Look up all ALBs in the cluster
data "aws_lbs" "all" {
  count = local.enable_cloudfront ? 1 : 0

  tags = {
    "eks:eks-cluster-name" = var.name
  }
}

# Look up individual ALB details
data "aws_lb" "services" {
  for_each = local.enable_cloudfront ? toset(try(data.aws_lbs.all[0].arns, [])) : toset([])
  arn      = each.value
}

# Map ALBs by their stack tag (namespace/ingress)
locals {
  alb_by_stack = local.enable_cloudfront ? {
    for arn, lb in data.aws_lb.services :
    try(lb.tags["ingress.eks.amazonaws.com/stack"], "") => lb.dns_name
    if try(lb.tags["ingress.eks.amazonaws.com/stack"], "") != ""
  } : {}

  # Service configuration with ALB DNS names
  cloudfront_services = local.enable_cloudfront ? {
    openwebui = {
      alb_dns_name = try(local.alb_by_stack["openwebui/openwebui"], "")
      description  = "Open WebUI"
    }
    litellm = {
      alb_dns_name = try(local.alb_by_stack["litellm/litellm"], "")
      description  = "LiteLLM Gateway"
    }
    langfuse = {
      alb_dns_name = try(local.alb_by_stack["langfuse/langfuse"], "")
      description  = "Langfuse Observability"
    }
    qdrant = {
      alb_dns_name = try(local.alb_by_stack["ingress-nginx/qdrant-alb"], "")
      description  = "Qdrant Vector DB"
    }
  } : {}

  # Filter out services without ALBs
  available_services = {
    for k, v in local.cloudfront_services : k => v if v.alb_dns_name != ""
  }
}

# Cache policy for dynamic content (no caching)
resource "aws_cloudfront_cache_policy" "no_cache" {
  count = local.enable_cloudfront && length(local.available_services) > 0 ? 1 : 0

  name        = "${var.name}-no-cache"
  comment     = "No caching for dynamic content"
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
  }
}

# Origin request policy - forward all necessary headers, cookies, query strings
resource "aws_cloudfront_origin_request_policy" "forward_all" {
  count = local.enable_cloudfront && length(local.available_services) > 0 ? 1 : 0

  name    = "${var.name}-forward-all"
  comment = "Forward all headers, cookies, and query strings"

  cookies_config {
    cookie_behavior = "all"
  }

  headers_config {
    header_behavior = "allViewerAndWhitelistCloudFront"
    headers {
      items = ["CloudFront-Forwarded-Proto"]
    }
  }

  query_strings_config {
    query_string_behavior = "all"
  }
}

# One CloudFront distribution per service
resource "aws_cloudfront_distribution" "services" {
  for_each = local.available_services

  enabled             = true
  comment             = "${var.name} - ${each.value.description}"
  default_root_object = ""
  price_class         = "PriceClass_100"

  origin {
    domain_name = each.value.alb_dns_name
    origin_id   = each.key

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = each.key

    cache_policy_id          = aws_cloudfront_cache_policy.no_cache[0].id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.forward_all[0].id

    viewer_protocol_policy = "redirect-to-https"
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name    = "${var.name}-${each.key}"
    Service = each.key
  }
}
