# Port Forwarding to Internal Services
# Usage: make <service>   (e.g., make litellm)
# Access: http://localhost:<port>

# Local ports
LITELLM_PORT = 4000
LANGFUSE_PORT = 3000
N8N_PORT = 5678
QDRANT_PORT = 6333
OPENWEBUI_PORT = 8080

.PHONY: help litellm langfuse n8n qdrant openwebui list-albs

help:
	@echo "Port Forwarding to Internal Services"
	@echo ""
	@echo "Usage: make <service>"
	@echo ""
	@echo "Services:"
	@echo "  litellm    - AI Gateway        → http://localhost:$(LITELLM_PORT)"
	@echo "  langfuse   - LLM Observability → http://localhost:$(LANGFUSE_PORT)"
	@echo "  n8n        - Workflow Auto     → http://localhost:$(N8N_PORT)"
	@echo "  qdrant     - Vector Database   → http://localhost:$(QDRANT_PORT)"
	@echo "  openwebui  - Chat UI           → http://localhost:$(OPENWEBUI_PORT)"
	@echo ""
	@echo "Other:"
	@echo "  list-albs  - Show all internal ALB hostnames"
	@echo ""
	@echo "Example:"
	@echo "  make litellm"
	@echo "  # Then open http://localhost:4000 in your browser"

list-albs:
	@AWS_PROFILE=dev aws elbv2 describe-load-balancers \
		--query "LoadBalancers[*].[LoadBalancerName,Scheme,DNSName]" \
		--output table --region us-east-1

litellm:
	@echo "Starting port forwarding to LiteLLM..."
	@echo "Access: http://localhost:$(LITELLM_PORT)"
	@echo "Press Ctrl+C to stop"
	@kubectl port-forward -n litellm svc/litellm $(LITELLM_PORT):4000

langfuse:
	@echo "Starting port forwarding to Langfuse..."
	@echo "Access: http://localhost:$(LANGFUSE_PORT)"
	@echo "Press Ctrl+C to stop"
	@kubectl port-forward -n langfuse svc/langfuse-web $(LANGFUSE_PORT):3000

n8n:
	@echo "Starting port forwarding to n8n..."
	@echo "Access: http://localhost:$(N8N_PORT)"
	@echo "Press Ctrl+C to stop"
	@kubectl port-forward -n n8n svc/n8n $(N8N_PORT):80

qdrant:
	@echo "Starting port forwarding to Qdrant..."
	@echo "Access: http://localhost:$(QDRANT_PORT)"
	@echo "Press Ctrl+C to stop"
	@kubectl port-forward -n qdrant svc/qdrant $(QDRANT_PORT):6333

openwebui:
	@echo "Starting port forwarding to OpenWebUI..."
	@echo "Access: http://localhost:$(OPENWEBUI_PORT)"
	@echo "Press Ctrl+C to stop"
	@kubectl port-forward -n openwebui svc/openwebui $(OPENWEBUI_PORT):80
