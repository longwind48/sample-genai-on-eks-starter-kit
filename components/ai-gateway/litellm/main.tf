variable "region" {
  type    = string
  default = "us-west-2"
}
variable "bedrock_region" {
  type    = string
  default = "us-west-2"
}
variable "name" {
  type    = string
  default = "genai-on-eks"
}
variable "enable_bedrock_guardrail" {
  type    = bool
  default = false
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
}
provider "aws" {
  alias  = "bedrock"
  region = var.bedrock_region
}

module "pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.12.0"

  name                 = "${var.name}-${var.region}-litellm"
  use_name_prefix      = false
  attach_custom_policy = true
  policy_statements = [
    {
      sid = "Bedrock"
      actions = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "aws-marketplace:Subscribe",
        "aws-marketplace:ViewSubscriptions",
        "bedrock:ApplyGuardrail"
      ]
      resources = ["*"]
    }
  ]
  associations = {
    litellm = {
      service_account = "litellm"
      namespace       = "litellm"
      cluster_name    = var.name
    }
  }
}

resource "aws_bedrock_guardrail" "this" {
  count                     = var.enable_bedrock_guardrail ? 1 : 0
  provider                  = aws.bedrock
  name                      = "${var.name}-claude-code"
  blocked_input_messaging   = "Sorry, this request was blocked by the content guardrail."
  blocked_outputs_messaging = "Sorry, this response was blocked by the content guardrail."
  description               = "Guardrail for Claude Code traffic - PII detection and profanity filter"

  sensitive_information_policy_config {
    pii_entities_config {
      action = "ANONYMIZE"
      type   = "US_SOCIAL_SECURITY_NUMBER"
    }
    pii_entities_config {
      action = "ANONYMIZE"
      type   = "CREDIT_DEBIT_CARD_NUMBER"
    }
    pii_entities_config {
      action = "ANONYMIZE"
      type   = "AWS_ACCESS_KEY"
    }
    pii_entities_config {
      action = "ANONYMIZE"
      type   = "AWS_SECRET_KEY"
    }
    pii_entities_config {
      action = "ANONYMIZE"
      type   = "US_PASSPORT_NUMBER"
    }
    pii_entities_config {
      action = "ANONYMIZE"
      type   = "DRIVER_ID"
    }
    pii_entities_config {
      action = "ANONYMIZE"
      type   = "US_INDIVIDUAL_TAX_IDENTIFICATION_NUMBER"
    }
  }

  word_policy_config {
    managed_word_lists_config {
      type = "PROFANITY"
    }
  }
}
output "bedrock_guardrail_id" {
  value = var.enable_bedrock_guardrail ? aws_bedrock_guardrail.this[0].guardrail_id : ""
}
resource "aws_bedrock_guardrail_version" "this" {
  count         = var.enable_bedrock_guardrail ? 1 : 0
  provider      = aws.bedrock
  description   = var.name
  guardrail_arn = aws_bedrock_guardrail.this[0].guardrail_arn
}
output "bedrock_guardrail_version" {
  value = var.enable_bedrock_guardrail ? aws_bedrock_guardrail_version.this[0].version : ""
}