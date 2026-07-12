# Spec: Amazon-Approved Public Exposure of LiteLLM

Status: Draft
Owner: tracilim
Date: 2026-07-12
Related: commit `9e1920f` (internal ALBs for DyePack compliance), `6e9df80` (Claude Code PII guardrail)

## Goal

Expose the LiteLLM AI gateway on a public HTTPS endpoint in an **Amazon-approved**
posture: the EKS ALB stays **internal** (DyePack-compliant), and the *only* public
entry point is a **CloudFront distribution fronted by AWS WAF**. Callers
authenticate with **LiteLLM virtual API keys** (no interactive SSO at the edge).

Success = a Claude Code / OpenAI-compatible client, from the public internet, can
`POST /chat/completions` with a valid virtual key over TLS, the request passes a
WAF managed-rule check, reaches LiteLLM through CloudFront → internal ALB, and is
served — while the ALB itself is unreachable directly from the internet.

## Non-goals

- Interactive auth (Midway/Cognito/OIDC) at the edge. Explicitly deferred — clients are programmatic. Revisit if a browser UI (OpenWebUI) is exposed the same way.
- Changing LiteLLM's internal authz/budget/guardrail model. It already does virtual keys, per-key budgets, and Bedrock PII guardrails — unchanged.
- Custom domain / Route53 / ACM-on-ALB. This spec targets the `DOMAIN=""` path (CloudFront default `*.cloudfront.net` cert). Custom-domain path is a follow-up.

## Current state (verified against live dev account 739907928487 / us-east-1, 2026-07-12)

| Fact | Evidence |
|---|---|
| EKS cluster `genai-on-eks` runs in **dev / us-east-1** | `aws eks list-clusters --region us-east-1` |
| LiteLLM ALB is **already `internal`** (DyePack posture correct) | `k8s-litellm-litellm-84b2c01d97`, scheme `internal`, DNS `internal-k8s-litellm-litellm-84b2c01d97-1573311892.us-east-1.elb.amazonaws.com`, VPC `vpc-0b11e079a1a180800`, 4 private subnets. ARN `.../k8s-litellm-litellm-84b2c01d97/067b8bcb4e885145` |
| Template `className` still says internet-facing, but internal wins live | `values.template.yaml:124` = `shared-internet-facing-alb`, yet live ALB is `internal` → template is stale/overridden. Fix to `shared-internal-alb` (ticket 4). |
| **No CloudFront distro for litellm exists live** | `aws cloudfront list-distributions` → 3 distros, all unrelated (`talrev-*`, `slidev`). None has an ALB origin. |
| `resources-us-east-1.txt` is a **planned-config resource dump, not live state** | Lists `data.aws_lb.services["…litellm…"]`, `aws_cloudfront_distribution.services["litellm/langfuse/n8n/openwebui/qdrant"]`, `aws_cloudfront_cache_policy.no_cache[0]`, `aws_cloudfront_origin_request_policy.forward_all[0]`. This is the fingerprint of a per-service CloudFront config that was authored but whose `.tf` is not in the repo and was never (or no longer) applied. → **author net-new, no import.** |
| **No WAF anywhere** | `aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1` → 0 |
| CloudFront **VPC origins** feature is available in the account | `aws cloudfront list-vpc-origins` → responds, 0 configured |
| LiteLLM auth = virtual keys only | `values.template.yaml:96,142` master_key + `store_model_in_db`; budgets at `:145-154` |

**Implication (corrected):** the CloudFront distro does NOT exist live, so this is **net-new authoring, not drift recovery — no `terraform import`.** The internal ALB cannot be a normal public CloudFront origin, so the design uses a **CloudFront VPC origin** pointing at the internal ALB. WAF is net-new.

## Design

```
Internet
   │  HTTPS (TLS 1.2+, *.cloudfront.net or custom domain)
   ▼
┌─────────────────────────────┐
│ CloudFront distribution      │  ← AWS WAF (CLOUDFRONT scope, us-east-1) attached
│  origin: internal ALB DNS    │     • AWSManagedRulesCommonRuleSet
│  cache: disabled (API)       │     • AWSManagedRulesKnownBadInputsRuleSet
│  OriginProtocolPolicy: https │     • rate-based rule (per-IP)
│  custom header: X-Origin-Verify (shared secret)
└──────────────┬──────────────┘
               │  only CloudFront can reach ALB:
               │  ALB is internal + SG ingress restricted to
               │  CloudFront managed-prefix-list (com.amazonaws.global.cloudfront.origin-facing)
               │  + ALB listener rule requires X-Origin-Verify header
               ▼
┌─────────────────────────────┐
│ Internal ALB (scheme:internal)│  className: shared-internal-alb (NOT internet-facing)
└──────────────┬──────────────┘
               ▼
        LiteLLM pods (2) → virtual-key authn → budget → guardrail → Bedrock/vLLM/TEI
```

### Key decisions

1. **ALB stays internal.** Revert the litellm ingress `className` from `shared-internet-facing-alb` to the internal class. Public reach comes only via CloudFront. Keeps DyePack posture from `9e1920f`.
2. **CloudFront is the sole public entry.** Cache disabled (LLM responses are non-cacheable, streaming); it's used purely as the approved WAF-fronted edge + TLS terminator.
3. **Origin lock-down (defense in depth), all three layers:**
   - ALB security-group ingress limited to the CloudFront `origin-facing` managed prefix list.
   - CloudFront injects a secret `X-Origin-Verify` custom header; an ALB listener rule (or LiteLLM) rejects requests without it → blocks anyone who resolves the ALB's internal DNS.
   - ALB remains `scheme: internal`.
4. **WAF managed rules + rate limiting**, WebACL in `us-east-1` at `CLOUDFRONT` scope (required for CloudFront). No IP allowlist (per decision: programmatic clients, keys-only).
5. **Auth stays LiteLLM virtual keys.** Edge adds TLS + WAF + rate limit only. The virtual key is the credential; WAF rate-limits brute force.

### Resolved: origin model = CloudFront VPC origin

The internal ALB is only reachable inside the VPC. **CloudFront VPC origins** (available
in this account — `list-vpc-origins` responds) let CloudFront target the internal ALB
privately, so the ALB never needs to be internet-facing. This is the truly-approved shape
and is now the chosen design — no internet-facing ALB, no public-prefix-list SG hack.

Defense in depth kept from the original design:
- VPC origin → ALB traffic stays inside AWS's private path.
- `X-Origin-Verify` shared-secret header injected by CloudFront; ALB listener rule (or LiteLLM) rejects requests lacking it — guards against anyone inside the VPC hitting the ALB directly.

### Open design risks

- **Streaming:** CloudFront must not buffer SSE. Confirm response streaming works through the distribution for `stream:true` completions. (Verify at ticket 5.)
- **VPC origin ↔ ALB SG:** the VPC origin needs a security group permitting CloudFront's managed VPC-origin ENIs to reach the ALB on 443. Wire in the module.

## Work breakdown (→ /to-tickets)

1. **Recover CloudFront Terraform into the repo** — author `components/networking/cloudfront/terraform/` (or a `terraform/modules/cloudfront/`) matching the existing live distro; `terraform import` the drifted `aws_cloudfront_distribution.services["litellm"]`. → verify: `terraform plan` shows no diff against live.
2. **Add WAFv2 WebACL** (CLOUDFRONT scope, us-east-1): common + known-bad-inputs managed rule groups + per-IP rate rule; associate to the distribution. → verify: WAF sampled-requests shows traffic evaluated; a synthetic bad-input request is blocked.
3. **Resolve origin model** (VPC origin vs internet-facing+locked ALB) — spike first. → verify: ALB not reachable from public internet by DNS; CloudFront path works.
4. **Flip litellm ingress to internal** (`className` + listen-ports) and wire the `X-Origin-Verify` secret check. → verify: direct ALB curl without header = 403; via CloudFront = 200.
5. **End-to-end test** — Claude Code / `curl` against the CloudFront URL with a virtual key: non-stream + stream, budget enforcement, guardrail PII masking still active. → verify: all pass.
6. **Docs + runbook** — update `docs/` accessing-services + a runbook for rotating the origin secret and WAF rule changes.

## Live verification results (dev/us-east-1, 2026-07-12, applied)

CloudFront `E3MZCN18Z9UBXE` = **https://d1dp7djmfph951.cloudfront.net**, VPC origin `vo_3QY2vvOckL9DJ10z213dyZ`, WAF `genai-on-eks-litellm-edge`, prefix list `pl-3b927c52`. All `Deployed`.

- ✅ `GET /health/liveliness` via CloudFront → **200** (full path CF → VPC origin → internal ALB → pod works)
- ✅ `GET /v1/models` no key → **401** (reaches LiteLLM auth); with master key → **200**, 11 models
- ✅ WAF probe (log4j UA + path-traversal body) → **403** (WAF actively blocking)
- ✅ litellm ALB scheme = `internal` (not internet-reachable)
- ⏳ New models (Fable 5 / gpt-oss / GPT-5.x) NOT yet listed — running pods predate the config/image change. Appear after litellm re-deploy.
- ⏳ ALB prefix-list lock NOT yet applied (SG still 0.0.0.0/0 on :80 — in-VPC only since ALB is internal). Applied by the re-deploy with `CLOUDFRONT_PREFIX_LIST_ID`.

**Re-deploy done (2026-07-12) — verified live end-to-end:**
- Opus 4.8 via `bedrock/` → `OPUS_OK`; Fable 5 + gpt-oss registered
- GPT-5.5 / GPT-5.4 via `bedrock-mantle/` on the **`/v1/responses`** endpoint, SigV4/Pod Identity → `status: completed`. No API key.
- Pods on v1.91.3, ALB locked to `pl-3b927c52`, all through CloudFront.

**Runtime gotchas hit + fixed (record for next deploy):**
1. Image tag format changed: newer litellm publishes `vX.Y.Z` (NOT `main-vX.Y.Z-stable`). Used `v1.91.3`.
2. litellm-helm upgrade fails on the immutable `litellm-migrations` Job — `kubectl -n litellm delete job litellm-migrations` before re-running.
3. litellm TF state had drifted (pod-identity policy + association existed but weren't in state) — `terraform import` both before apply.
4. GPT-5.x is **Responses-API only**: call `/v1/responses`, NOT `/chat/completions` (LiteLLM #30941 — no auto-bridge yet).
5. mantle needs IAM action **`bedrock-mantle:CreateInference`** (+ `Get*`/`List*`) — distinct from `bedrock:InvokeModel`. Added to the litellm pod-identity policy.

Cost-allocation tags (Owner/CostCenter/Project/Environment/auto-delete/ManagedBy) applied to CloudFront + WAF + VPC origin, matching `terraform/variables.tf` default_tags.

## Verification (definition of done)

- [ ] `curl https://<dist>.cloudfront.net/v1/chat/completions -H "Authorization: Bearer <vkey>"` returns a completion.
- [ ] Same request with `stream:true` streams tokens (no buffering).
- [ ] Direct request to the ALB DNS (no CloudFront header) → 403/timeout.
- [ ] WAF blocks a known-bad-input probe; rate rule trips under burst.
- [ ] `terraform plan` clean (no drift) for CloudFront + WAF.
- [ ] Bedrock PII guardrail still masks in responses through the new path.
- [ ] Budget-exceeded key still returns 400.

## Addendum: GPT-5.4/5.5 + Fable 5 model additions (2026-07-12)

Requested alongside the exposure work. Verified against live Bedrock (dev/us-east-1) and AWS docs:

- **Fable 5** → `global.anthropic.claude-fable-5` (inference profile). Added to `config.json` `bedrock.llm`. Uses the existing `bedrock/` (SigV4/Pod Identity) path. ✓ works on current image.
- **gpt-oss-120b / 20b** → `openai.gpt-oss-120b-1:0` / `openai.gpt-oss-20b-1:0`. Added to `bedrock.llm`. Invoke-capable, `bedrock/` path. ✓
- **GPT-5.5 / GPT-5.4** → `openai.gpt-5.5` / `openai.gpt-5.4`. **Bedrock Mantle only** (Responses API, endpoint `https://bedrock-mantle.{region}.api.aws/openai/v1`, NOT the `bedrock/` invoke path, NOT Converse). Added a separate `bedrock.mantle` config section + a `bedrock_mantle/` template branch.
  - **Auth = SigV4 via EKS Pod Identity, NO API key.** LiteLLM ≥ v1.87.2 (PR #29788) SigV4-signs mantle Responses requests from the standard AWS credential chain when no bearer token is set — the same Pod Identity role the `bedrock/` models use. This avoids the short-term Bedrock API key problem (≤12h TTL, needs `aws-bedrock-token-generator` refresh); we omit `api_key` so LiteLLM falls back to SigV4. Requires image ≥ v1.87.2 (we pin v1.91.3).
  - Note (not applicable to us): PR #30714 review flagged SigV4 headers going to a caller-controlled `api_base`. We pin `api_base` server-side in the template, so callers can't redirect it.

**BLOCKER for GPT-5.x:** the pinned LiteLLM image `main-v1.81.3-stable` (released 2026-01-26) **predates the `bedrock_mantle` provider** (added 2026-03-05, PR #22866). Current stable is ~v1.91 (Jul 2026). **GPT-5.x config is inert until the image is bumped.** Also note LiteLLM issues #29463 / #30941 (open) about GPT-5.x Responses-API auto-conversion on mantle — validate end-to-end after bumping. Fable 5 and gpt-oss are unaffected and work on the current image.

Runtime enablement: GPT-5.x, gpt-oss, and Fable 5 each need Bedrock model access granted in the account before invoke succeeds.

## Cost / ops notes

- CloudFront: request + data-transfer-out pricing; negligible vs Bedrock token cost.
- WAF: ~$5/mo per WebACL + $1/rule + per-request. Two managed groups + 1 rate rule ≈ low-single-digit $/mo baseline.
- Origin secret rotation is manual until automated — runbook item.
