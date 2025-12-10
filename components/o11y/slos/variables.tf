variable "region" {
  type    = string
  default = "us-east-1"
}

variable "slos" {
  description = "Map of SLOs to create"
  type = map(object({
    description     = string
    alb_name        = string
    type            = string # "availability" or "latency"
    threshold       = number
    attainment_goal = number
    rolling_days    = number
  }))
  default = {
    "openwebui-availability" = {
      description     = "OpenWebUI availability - 99.5% success rate"
      alb_name        = "app/k8s-openwebu-openwebu-8757f6a3a1/541acb52418a2577"
      type            = "availability"
      threshold       = 99.5
      attainment_goal = 99.5
      rolling_days    = 30
    }
    "openwebui-latency" = {
      description     = "OpenWebUI latency - P99 under 5 seconds"
      alb_name        = "app/k8s-openwebu-openwebu-8757f6a3a1/541acb52418a2577"
      type            = "latency"
      threshold       = 5.0
      attainment_goal = 99.5
      rolling_days    = 30
    }
    "litellm-availability" = {
      description     = "LiteLLM availability - 99.5% success rate"
      alb_name        = "app/k8s-litellm-litellm-8bf73c39ce/710c938172a120ae"
      type            = "availability"
      threshold       = 99.5
      attainment_goal = 99.5
      rolling_days    = 30
    }
    "litellm-latency" = {
      description     = "LiteLLM latency - P99 under 30 seconds"
      alb_name        = "app/k8s-litellm-litellm-8bf73c39ce/710c938172a120ae"
      type            = "latency"
      threshold       = 30.0
      attainment_goal = 99.5
      rolling_days    = 30
    }
  }
}
