#!/usr/bin/env zx

import { fileURLToPath } from "url";
import path from "path";
import { $ } from "zx";
$.verbose = true;

export const name = "CloudFront CDN";
const __filename = fileURLToPath(import.meta.url);
const DIR = path.dirname(__filename);
let BASE_DIR;
let config;
let utils;

export async function init(_BASE_DIR, _config, _utils) {
  BASE_DIR = _BASE_DIR;
  config = _config;
  utils = _utils;
}

export async function install() {
  const { DOMAIN } = process.env;

  // CloudFront is only needed when DOMAIN is not set
  if (DOMAIN && DOMAIN !== "") {
    console.log("CloudFront is not needed when DOMAIN is set.");
    console.log("With a custom domain, use the shared ALB with HTTPS instead.");
    console.log("Skipping CloudFront installation.");
    return;
  }

  console.log("Installing CloudFront CDN for HTTPS access...\n");

  // Check which services are deployed
  console.log("Checking for deployed services...");
  const services = [
    { name: "openwebui", namespace: "openwebui", ingress: "openwebui" },
    { name: "litellm", namespace: "litellm", ingress: "litellm" },
    { name: "langfuse", namespace: "langfuse", ingress: "langfuse" },
    { name: "qdrant", namespace: "ingress-nginx", ingress: "qdrant-alb" },
  ];

  let foundServices = 0;
  for (const svc of services) {
    try {
      const result = await $`kubectl get ingress ${svc.ingress} -n ${svc.namespace} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null`;
      const hostname = result.stdout.trim().replace(/'/g, "");
      if (hostname) {
        console.log(`  ✓ ${svc.name}: ${hostname}`);
        foundServices++;
      } else {
        console.log(`  ✗ ${svc.name}: ALB not ready`);
      }
    } catch (error) {
      console.log(`  ✗ ${svc.name}: not deployed`);
    }
  }

  if (foundServices === 0) {
    console.log("\nNo services with ALBs found. Please deploy services first:");
    console.log("  ./cli gui-app openwebui install");
    console.log("  ./cli ai-gateway litellm install");
    console.log("  ./cli o11y langfuse install");
    throw new Error("No services available for CloudFront");
  }

  console.log(`\nFound ${foundServices} service(s) with ALBs. Deploying CloudFront...\n`);

  // Apply main Terraform (CloudFront uses data sources to find ALBs)
  const TERRAFORM_DIR = path.join(BASE_DIR, "terraform");
  await utils.terraform.apply(TERRAFORM_DIR);

  // Get outputs
  console.log("\n--- CloudFront Deployment Complete ---\n");

  try {
    const cloudfrontUrl = await utils.terraform.output(TERRAFORM_DIR, { outputName: "cloudfront_url" });
    if (cloudfrontUrl && cloudfrontUrl !== "null") {
      console.log(`CloudFront URL: ${cloudfrontUrl}\n`);
      console.log("Service URLs:");
      console.log(`  openwebui: ${cloudfrontUrl}/openwebui`);
      console.log(`  litellm:   ${cloudfrontUrl}/litellm`);
      console.log(`  langfuse:  ${cloudfrontUrl}/langfuse`);
      console.log(`  qdrant:    ${cloudfrontUrl}/qdrant`);
      console.log("\nNote: CloudFront distribution may take 5-10 minutes to fully deploy.");
    } else {
      console.log("CloudFront was not created (check if services have ALBs).");
    }
  } catch (error) {
    console.log("Could not retrieve CloudFront URL. Run './cli terraform output' to check.");
  }
}

export async function uninstall() {
  console.log("CloudFront will be removed when infrastructure is destroyed.");
  console.log("Run './cli cleanup-everything' to remove all resources.");
}
