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
      version = "~> 6.0"
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
    },
    {
      # GPT-5.x etc. on the bedrock-mantle endpoint. CreateInference authorizes
      # both Chat Completions and Responses calls; SigV4 auth (pod IAM) needs no
      # CallWithBearerToken. Scoped to mantle projects in-account.
      sid = "BedrockMantleInference"
      actions = [
        "bedrock-mantle:CreateInference",
        "bedrock-mantle:Get*",
        "bedrock-mantle:List*"
      ]
      resources = ["arn:aws:bedrock-mantle:*:*:project/*"]
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

locals {
  # PII types masked in both directions. NAME / ADDRESS are deliberately absent -
  # they fire on ordinary prose and would mangle most legitimate traffic.
  masked_pii_entities = [
    "US_SOCIAL_SECURITY_NUMBER",
    "CREDIT_DEBIT_CARD_NUMBER",
    "AWS_ACCESS_KEY",
    "AWS_SECRET_KEY",
    "US_PASSPORT_NUMBER",
    "DRIVER_ID",
    "US_INDIVIDUAL_TAX_IDENTIFICATION_NUMBER",
    "EMAIL",
    "PHONE",
  ]

  # Harmful-content filters, on both guardrails. Strength is a confidence THRESHOLD,
  # not an intensity dial: HIGH blocks LOW+MEDIUM+HIGH confidence hits, MEDIUM blocks
  # MEDIUM+HIGH, LOW blocks HIGH only. Drop a noisy category a notch rather than
  # deleting it. MISCONDUCT sits at MEDIUM because at HIGH it fired on LOW confidence
  # and blocked a plain "here is my SSN and card number" prompt that should have masked.
  content_filters = [
    { type = "HATE", input = "HIGH", output = "HIGH" },
    { type = "INSULTS", input = "HIGH", output = "HIGH" },
    { type = "SEXUAL", input = "HIGH", output = "HIGH" },
    { type = "VIOLENCE", input = "HIGH", output = "HIGH" },
    { type = "MISCONDUCT", input = "MEDIUM", output = "MEDIUM" },
  ]

  # PROMPT_ATTACK is input-only (Bedrock rejects any output_strength but NONE) and is
  # on the strict guardrail ONLY. Agentic clients (Claude Code, Claude Desktop/Cowork)
  # inject persona and behaviour-override text into the USER turn - hooks, system
  # reminders, pasted docs. Bedrock scores that as an injection attempt at HIGH
  # confidence, and because a BLOCK pre-empts ANONYMIZE the request is refused before
  # PII masking can run. Strength does not help: LOW still blocks HIGH confidence.
  prompt_attack_filter = [
    { type = "PROMPT_ATTACK", input = "MEDIUM", output = "NONE" },
  ]
}

resource "aws_bedrock_guardrail" "this" {
  count                     = var.enable_bedrock_guardrail ? 1 : 0
  provider                  = aws.bedrock
  name                      = "${var.name}-claude-code"
  blocked_input_messaging   = "Sorry, this request was blocked by the content guardrail."
  blocked_outputs_messaging = "Sorry, this response was blocked by the content guardrail."
  description               = "STRICT: PII masking, content filters, prompt-attack defense. Opt-in per key - blocks agentic clients."

  content_policy_config {
    dynamic "filters_config" {
      for_each = concat(local.prompt_attack_filter, local.content_filters)
      content {
        type            = filters_config.value.type
        input_strength  = filters_config.value.input
        output_strength = filters_config.value.output
      }
    }
  }

  sensitive_information_policy_config {
    dynamic "pii_entities_config" {
      for_each = local.masked_pii_entities
      content {
        type = pii_entities_config.value
        # `action` alone only masks the model RESPONSE - on the prompt it is a no-op.
        # input_action is what actually masks PII on the way in, so set both.
        action         = "ANONYMIZE"
        input_action   = "ANONYMIZE"
        output_action  = "ANONYMIZE"
        input_enabled  = true
        output_enabled = true
      }
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

  # A version is an immutable snapshot of DRAFT. Editing the guardrail above does
  # not move it, so without this LiteLLM stays pinned to a stale policy - the edit
  # applies and silently has no effect. Cut a fresh version on every policy change.
  lifecycle {
    replace_triggered_by = [aws_bedrock_guardrail.this[0]]
  }
}
output "bedrock_guardrail_version" {
  value = var.enable_bedrock_guardrail ? aws_bedrock_guardrail_version.this[0].version : ""
}

# The gateway default. Same PII masking and content filters as the strict guardrail,
# minus PROMPT_ATTACK, so agentic clients work while PII masking still applies to
# every key. Prompt-attack defense is opt-in via the strict guardrail above.
resource "aws_bedrock_guardrail" "agentic" {
  count                     = var.enable_bedrock_guardrail ? 1 : 0
  provider                  = aws.bedrock
  name                      = "${var.name}-agentic"
  blocked_input_messaging   = "Sorry, this request was blocked by the content guardrail."
  blocked_outputs_messaging = "Sorry, this response was blocked by the content guardrail."
  description               = "DEFAULT: PII masking + content filters, no prompt-attack. Safe for agentic clients."

  content_policy_config {
    dynamic "filters_config" {
      for_each = local.content_filters
      content {
        type            = filters_config.value.type
        input_strength  = filters_config.value.input
        output_strength = filters_config.value.output
      }
    }
  }

  sensitive_information_policy_config {
    dynamic "pii_entities_config" {
      for_each = local.masked_pii_entities
      content {
        type           = pii_entities_config.value
        action         = "ANONYMIZE"
        input_action   = "ANONYMIZE"
        output_action  = "ANONYMIZE"
        input_enabled  = true
        output_enabled = true
      }
    }
  }

  word_policy_config {
    managed_word_lists_config {
      type = "PROFANITY"
    }
  }
}
output "bedrock_guardrail_agentic_id" {
  value = var.enable_bedrock_guardrail ? aws_bedrock_guardrail.agentic[0].guardrail_id : ""
}
resource "aws_bedrock_guardrail_version" "agentic" {
  count         = var.enable_bedrock_guardrail ? 1 : 0
  provider      = aws.bedrock
  description   = "${var.name}-agentic"
  guardrail_arn = aws_bedrock_guardrail.agentic[0].guardrail_arn

  lifecycle {
    replace_triggered_by = [aws_bedrock_guardrail.agentic[0]]
  }
}
output "bedrock_guardrail_agentic_version" {
  value = var.enable_bedrock_guardrail ? aws_bedrock_guardrail_version.agentic[0].version : ""
}