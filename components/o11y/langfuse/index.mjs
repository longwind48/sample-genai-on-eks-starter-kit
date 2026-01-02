#!/usr/bin/env zx

import { fileURLToPath } from "url";
import path from "path";
import fs from "fs";
import handlebars from "handlebars";
import { $ } from "zx";
$.verbose = true;

export const name = "Langfuse";
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
  const requiredEnvVars = ["LANGFUSE_USERNAME", "LANGFUSE_PASSWORD", "LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY"];
  utils.checkRequiredEnvVars(requiredEnvVars);

  await utils.terraform.apply(DIR);
  const tfOutput = await utils.terraform.output(DIR, {});
  const langfuseBucketName = tfOutput.langfuse_bucket_name.value;

  await $`helm repo add langfuse https://langfuse.github.io/langfuse-k8s`;
  await $`helm repo update`;

  const valuesTemplatePath = path.join(DIR, "values.template.yaml");
  const valuesRenderedPath = path.join(DIR, "values.rendered.yaml");
  const valuesTemplateString = fs.readFileSync(valuesTemplatePath, "utf8");
  const valuesTemplate = handlebars.compile(valuesTemplateString);
  // Get Langfuse URL from env or terraform CloudFront output
  let langfuseUrl = process.env.LANGFUSE_URL;
  if (!langfuseUrl) {
    try {
      const TERRAFORM_DIR = path.join(BASE_DIR, "terraform");
      const allOutputs = await utils.terraform.output(TERRAFORM_DIR, {});
      if (allOutputs?.cloudfront_urls?.value?.langfuse) {
        langfuseUrl = allOutputs.cloudfront_urls.value.langfuse;
      }
    } catch (e) {
      // CloudFront not configured, skip
    }
  }

  const valuesVars = {
    DOMAIN: process.env.DOMAIN,
    LANGFUSE_USERNAME: process.env.LANGFUSE_USERNAME,
    LANGFUSE_PASSWORD: process.env.LANGFUSE_PASSWORD,
    LANGFUSE_PUBLIC_KEY: process.env.LANGFUSE_PUBLIC_KEY,
    LANGFUSE_SECRET_KEY: process.env.LANGFUSE_SECRET_KEY,
    LANGFUSE_BUCKET_NAME: langfuseBucketName,
    LANGFUSE_URL: langfuseUrl,
    AWS_REGION: process.env.AWS_REGION,
  };
  fs.writeFileSync(valuesRenderedPath, valuesTemplate(valuesVars));

  // Create ConfigMap to disable verbose ClickHouse system logging
  // This prevents disk from filling up with internal logs (trace_log, text_log, etc.)
  console.log("Creating ClickHouse config overrides ConfigMap...");
  await $`kubectl create namespace langfuse --dry-run=client -o yaml | kubectl apply -f -`;
  await $`kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: clickhouse-config-overrides
  namespace: langfuse
data:
  disable-system-logs.xml: |
    <clickhouse>
      <!-- Configure TTL for system log tables to prevent disk bloat -->
      <!-- These are ClickHouse internal diagnostics, not Langfuse data -->
      <trace_log>
        <ttl>event_date + INTERVAL 1 DAY DELETE</ttl>
      </trace_log>
      <text_log>
        <ttl>event_date + INTERVAL 1 DAY DELETE</ttl>
      </text_log>
      <metric_log>
        <ttl>event_date + INTERVAL 1 DAY DELETE</ttl>
      </metric_log>
      <query_log>
        <ttl>event_date + INTERVAL 1 DAY DELETE</ttl>
      </query_log>
      <asynchronous_metric_log>
        <ttl>event_date + INTERVAL 1 DAY DELETE</ttl>
      </asynchronous_metric_log>
      <latency_log>
        <ttl>event_date + INTERVAL 1 DAY DELETE</ttl>
      </latency_log>
    </clickhouse>
EOF`;

  await $`helm upgrade --install langfuse langfuse/langfuse --namespace langfuse --create-namespace -f ${valuesRenderedPath}`;
}

export async function uninstall() {
  await $`helm uninstall langfuse --namespace langfuse`;
  await utils.terraform.destroy(DIR);
}
