# IAM Role for MCP Proxy (EKS Pod Identity)
# Add this to your terraform/eks-addons.tf or similar

resource "aws_iam_role" "mcp_proxy" {
  name = "${module.eks.cluster_name}-${var.region}-mcp-proxy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "mcp_proxy_agentcore" {
  name = "agentcore-invoke"
  role = aws_iam_role.mcp_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:InvokeAgentRuntime"
        ]
        Resource = var.agentcore_runtime_arn
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "mcp_proxy" {
  cluster_name    = module.eks.cluster_name
  namespace       = "openwebui"
  service_account = "mcp-proxy"
  role_arn        = aws_iam_role.mcp_proxy.arn
}

variable "agentcore_runtime_arn" {
  type    = string
  default = "arn:aws:bedrock-agentcore:us-east-1:739907928487:runtime/hosted_agent_eq97r-L7DvQ9Ffu0"
}
