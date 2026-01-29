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

# Create SLOs using AWS CLI via local-exec
# Note: AWS provider doesn't have native Application Signals SLO support yet
resource "terraform_data" "slo" {
  for_each = var.slos

  # Store values that destroy provisioner needs
  input = {
    name   = each.key
    region = var.region
  }

  triggers_replace = {
    name        = each.key
    config_hash = sha256(jsonencode(each.value))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      # Build SLI config based on type
      if [ "${each.value.type}" = "availability" ]; then
        SLI_CONFIG=$(cat <<'SLIEOF'
{
  "SliMetricConfig": {
    "MetricDataQueries": [
      {
        "Id": "errors",
        "MetricStat": {
          "Metric": {
            "Namespace": "AWS/ApplicationELB",
            "MetricName": "HTTPCode_Target_5XX_Count",
            "Dimensions": [{"Name": "LoadBalancer", "Value": "${each.value.alb_name}"}]
          },
          "Period": 60,
          "Stat": "Sum"
        },
        "ReturnData": false
      },
      {
        "Id": "requests",
        "MetricStat": {
          "Metric": {
            "Namespace": "AWS/ApplicationELB",
            "MetricName": "RequestCount",
            "Dimensions": [{"Name": "LoadBalancer", "Value": "${each.value.alb_name}"}]
          },
          "Period": 60,
          "Stat": "Sum"
        },
        "ReturnData": false
      },
      {
        "Id": "availability",
        "Expression": "100 - (errors / requests) * 100",
        "ReturnData": true
      }
    ],
    "MetricType": "AVAILABILITY"
  },
  "MetricThreshold": ${each.value.threshold},
  "ComparisonOperator": "GreaterThanOrEqualTo"
}
SLIEOF
)
      else
        SLI_CONFIG=$(cat <<'SLIEOF'
{
  "SliMetricConfig": {
    "MetricDataQueries": [
      {
        "Id": "latency",
        "MetricStat": {
          "Metric": {
            "Namespace": "AWS/ApplicationELB",
            "MetricName": "TargetResponseTime",
            "Dimensions": [{"Name": "LoadBalancer", "Value": "${each.value.alb_name}"}]
          },
          "Period": 60,
          "Stat": "p99"
        },
        "ReturnData": true
      }
    ],
    "MetricType": "LATENCY"
  },
  "MetricThreshold": ${each.value.threshold},
  "ComparisonOperator": "LessThanOrEqualTo"
}
SLIEOF
)
      fi

      GOAL_CONFIG='{"Interval": {"RollingInterval": {"DurationUnit": "DAY", "Duration": ${each.value.rolling_days}}}, "AttainmentGoal": ${each.value.attainment_goal}}'

      # Check if SLO already exists
      EXISTING=$(aws application-signals list-service-level-objectives \
        --query "SloSummaries[?Name=='${each.key}'].Arn" \
        --output text \
        --region ${var.region} 2>/dev/null)

      if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
        echo "SLO ${each.key} already exists with ARN: $EXISTING"
      else
        echo "Creating SLO: ${each.key}"
        aws application-signals create-service-level-objective \
          --name "${each.key}" \
          --description "${each.value.description}" \
          --sli-config "$SLI_CONFIG" \
          --goal "$GOAL_CONFIG" \
          --region ${var.region}
      fi
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      SLO_ARN=$(aws application-signals list-service-level-objectives \
        --query "SloSummaries[?Name=='${self.input.name}'].Arn" \
        --output text \
        --region ${self.input.region} 2>/dev/null)

      if [ -n "$SLO_ARN" ] && [ "$SLO_ARN" != "None" ]; then
        echo "Deleting SLO: ${self.input.name} ($SLO_ARN)"
        aws application-signals delete-service-level-objective \
          --id "$SLO_ARN" \
          --region ${self.input.region} 2>/dev/null || true
      else
        echo "SLO ${self.input.name} not found, skipping deletion"
      fi
    EOT
  }
}
