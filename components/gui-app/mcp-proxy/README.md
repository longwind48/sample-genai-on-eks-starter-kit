# MCP Proxy for AWS - Architecture Overview

## Why MCP Proxy for AWS is Needed

OpenWebUI cannot directly communicate with AWS Bedrock AgentCore runtimes due to two fundamental incompatibilities.

### 1. Transport Protocol Mismatch

| Component | Transport | Protocol |
|-----------|-----------|----------|
| OpenWebUI | HTTP (Streamable HTTP) | MCP client |
| AgentCore Runtime | AWS HTTPS API | MCP server (stdio-based internally) |

- **OpenWebUI** expects to connect to MCP servers via HTTP endpoints (`/mcp` or `/sse`)
- **AgentCore runtimes** expose an AWS API endpoint that requires AWS SigV4 request signing
- AgentCore's MCP implementation uses stdio transport internally, wrapped in an AWS API

### 2. AWS SigV4 Authentication

AgentCore endpoints require every request to be signed with AWS credentials:

```
https://bedrock-agentcore.{region}.amazonaws.com/runtimes/{arn}/invocations
```

- Requests must include `Authorization`, `X-Amz-Date`, `X-Amz-Security-Token` headers
- OpenWebUI's MCP client cannot sign AWS requests - it only supports basic HTTP with optional Bearer tokens
- The signature must be computed per-request using the AWS Signature Version 4 algorithm

### 3. The Solution: mcp-proxy + mcp-proxy-for-aws

```
┌─────────────┐      HTTP/MCP       ┌─────────────────────────────────────┐      SigV4 signed      ┌─────────────┐
│  OpenWebUI  │ ──────────────────► │  mcp-proxy  +  mcp-proxy-for-aws   │ ───────────────────►   │  AgentCore  │
│ (MCP client)│   Streamable HTTP   │  (Protocol bridge + AWS signer)    │   AWS HTTPS API        │   Runtime   │
└─────────────┘                     └─────────────────────────────────────┘                        └─────────────┘
```

**mcp-proxy** (by sparfenyuk):
- Exposes HTTP endpoints (`/mcp`, `/sse`) for MCP clients
- Converts HTTP transport to stdio transport
- Manages MCP sessions

**mcp-proxy-for-aws** (by awslabs):
- Wraps AWS API calls with SigV4 signing
- Handles AWS credentials (from environment, IAM roles, etc.)
- Translates MCP stdio protocol to AgentCore's invocation API

### 4. Why Not Just Use AWS SDK in OpenWebUI?

- OpenWebUI is a generic chat UI - it doesn't have AWS SDK integration
- MCP is designed to be provider-agnostic
- Adding AWS-specific code to OpenWebUI would break its modular architecture
- The proxy pattern allows any MCP client to use AgentCore without modification

### 5. EKS Pod Identity Integration

The proxy runs in EKS with Pod Identity, allowing it to:
- Automatically obtain AWS credentials without hardcoding secrets
- Assume an IAM role with `bedrock-agentcore:InvokeAgentRuntime` permission
- Refresh credentials automatically

## Why Are Both mcp-proxy and mcp-proxy-for-aws Needed?

Yes, for OpenWebUI you need both. Here's why:

| Component | Role | Transport |
|-----------|------|-----------|
| **mcp-proxy-for-aws** | MCP client that handles AWS SigV4 signing | stdio (designed for Claude Desktop, Q CLI, Cursor) |
| **mcp-proxy** | Protocol bridge that converts HTTP ↔ stdio | Exposes HTTP endpoints |
| **OpenWebUI** | MCP client | Only speaks HTTP (Streamable HTTP) |

### Detailed Architecture

```
OpenWebUI ──HTTP──► mcp-proxy ──stdio──► mcp-proxy-for-aws ──SigV4──► AgentCore
           (client)  (HTTP→stdio)         (AWS signer)                  (server)
```

### Why Can't mcp-proxy-for-aws Run Standalone?

`mcp-proxy-for-aws` is a **client-side proxy** designed to be invoked as a subprocess (stdio) by tools like:
- Claude Desktop
- Amazon Q Developer CLI
- Cursor
- Kiro

These tools manage the subprocess and communicate via stdin/stdout. It doesn't expose an HTTP server.

### Alternative: If OpenWebUI Supported stdio

If OpenWebUI could spawn subprocesses directly (like Claude Desktop does), you could skip `mcp-proxy`:
```
OpenWebUI ──stdio──► mcp-proxy-for-aws ──SigV4──► AgentCore
```

But OpenWebUI only supports HTTP-based MCP servers, hence the need for `mcp-proxy` as a bridge.

## Summary

| Without Proxy | With Proxy |
|---------------|------------|
| OpenWebUI can't sign AWS requests | Proxy handles SigV4 signing |
| Transport mismatch (HTTP vs AWS API) | Proxy bridges protocols |
| No IAM integration | Pod Identity provides credentials |
| Would require OpenWebUI code changes | Zero changes to OpenWebUI |

## Configuration in OpenWebUI

1. Go to **Admin Panel > Settings > Tools > Tool Servers**
2. Add a new tool server:
   - **URL**: `http://mcp-proxy.openwebui:8080/mcp`
   - **Type**: Streamable HTTP
   - **Auth**: None
3. Add any value to the **Function Name Filter List** (required due to OpenWebUI bug in v0.6.38+)

## References

- [mcp-proxy](https://github.com/sparfenyuk/mcp-proxy) - HTTP to stdio MCP bridge
- [mcp-proxy-for-aws](https://github.com/awslabs/mcp-proxy-for-aws) - AWS SigV4 signing for MCP
- [Bedrock AgentCore](https://docs.aws.amazon.com/bedrock/latest/userguide/agents-core.html) - AWS managed MCP runtime
