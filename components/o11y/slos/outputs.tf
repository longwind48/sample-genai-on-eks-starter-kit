output "slo_names" {
  description = "Names of created SLOs"
  value       = keys(var.slos)
}

output "slo_summary" {
  description = "Summary of SLO configurations"
  value = {
    for name, config in var.slos : name => {
      type            = config.type
      threshold       = config.threshold
      attainment_goal = config.attainment_goal
      rolling_days    = config.rolling_days
    }
  }
}
