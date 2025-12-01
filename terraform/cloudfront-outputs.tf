# CloudFront outputs - one URL per service

output "cloudfront_urls" {
  description = "CloudFront HTTPS URLs for each service"
  value = local.enable_cloudfront ? {
    for name, dist in aws_cloudfront_distribution.services :
    name => "https://${dist.domain_name}"
  } : null
}

output "cloudfront_distribution_ids" {
  description = "CloudFront distribution IDs for each service"
  value = local.enable_cloudfront ? {
    for name, dist in aws_cloudfront_distribution.services :
    name => dist.id
  } : null
}

# Individual outputs for convenience
output "openwebui_url" {
  description = "Open WebUI HTTPS URL"
  value       = local.enable_cloudfront && contains(keys(local.available_services), "openwebui") ? "https://${aws_cloudfront_distribution.services["openwebui"].domain_name}" : null
}

output "litellm_url" {
  description = "LiteLLM HTTPS URL"
  value       = local.enable_cloudfront && contains(keys(local.available_services), "litellm") ? "https://${aws_cloudfront_distribution.services["litellm"].domain_name}" : null
}

output "langfuse_url" {
  description = "Langfuse HTTPS URL"
  value       = local.enable_cloudfront && contains(keys(local.available_services), "langfuse") ? "https://${aws_cloudfront_distribution.services["langfuse"].domain_name}" : null
}

output "qdrant_url" {
  description = "Qdrant HTTPS URL"
  value       = local.enable_cloudfront && contains(keys(local.available_services), "qdrant") ? "https://${aws_cloudfront_distribution.services["qdrant"].domain_name}" : null
}
