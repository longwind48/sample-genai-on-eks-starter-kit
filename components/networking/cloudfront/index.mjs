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
  console.log("Exposing litellm publicly via CloudFront + WAF (internal ALB stays internal)...\n");

  // The litellm ingress must exist and its internal ALB must be provisioned,
  // because the terraform discovers it by tag.
  try {
    const result = await $`kubectl get ingress litellm -n litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null`;
    const hostname = result.stdout.trim().replace(/'/g, "");
    if (!hostname) {
      throw new Error("litellm ALB not ready");
    }
    console.log(`  ✓ litellm internal ALB: ${hostname}`);
  } catch (error) {
    console.log("\nlitellm ingress/ALB not found. Deploy litellm first:");
    console.log("  ./cli ai-gateway litellm install");
    throw new Error("litellm ALB not available for CloudFront");
  }

  console.log("\nDeploying CloudFront distribution + WAF (VPC origin -> internal ALB)...\n");

  const TERRAFORM_DIR = path.join(DIR, "terraform");
  await utils.terraform.apply(TERRAFORM_DIR, {
    vars: {
      region: process.env.REGION || "us-east-1",
      expose_litellm_public: true,
    },
  });

  console.log("\n--- CloudFront Deployment Complete ---\n");

  try {
    const cloudfrontUrl = await utils.terraform.output(TERRAFORM_DIR, { outputName: "litellm_cloudfront_url" });
    const prefixListId = await utils.terraform.output(TERRAFORM_DIR, { outputName: "cloudfront_prefix_list_id" });
    if (cloudfrontUrl && cloudfrontUrl !== "null" && cloudfrontUrl !== "") {
      console.log(`litellm CloudFront URL: ${cloudfrontUrl}`);
      console.log("\nNext step: lock the litellm ALB to CloudFront edge IPs. Re-run the");
      console.log("litellm install with CLOUDFRONT_PREFIX_LIST_ID set so the ingress adds");
      console.log("the security-group-prefix-lists annotation:");
      console.log(`  CLOUDFRONT_PREFIX_LIST_ID=${prefixListId} ./cli ai-gateway litellm install`);
      console.log("\nNote: the distribution may take 5-10 minutes to fully deploy.");
    } else {
      console.log("CloudFront was not created (expose_litellm_public may be false).");
    }
  } catch (error) {
    console.log("Could not retrieve CloudFront outputs. Run './cli networking cloudfront' terraform output to check.");
  }
}

export async function uninstall() {
  console.log("Removing litellm CloudFront distribution + WAF...\n");
  const TERRAFORM_DIR = path.join(DIR, "terraform");
  await utils.terraform.destroy(TERRAFORM_DIR, {
    vars: {
      region: process.env.REGION || "us-east-1",
      expose_litellm_public: true,
    },
  });
}
