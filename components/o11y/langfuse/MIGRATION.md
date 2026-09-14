# Langfuse v4 migration — dev

Account `739907928487`, region `us-east-1`, cluster `genai-on-eks`, context
`genai-dev`. Always use `AWS_PROFILE=dev`.

## Deployment ownership

- `langfuse-v2`: chart 2.1.0, application 4.35.0, new PostgreSQL and ClickHouse
  26.4 / Keeper. ClickHouse has a 40 GiB volume.
- `langfuse`: retained chart 1.5.16, web/worker at zero replicas. Owns the
  existing ingress, service account, Redis, and archived PostgreSQL/ClickHouse/
  ZooKeeper volumes. **Do not uninstall this release.**
- `langfuse-web` keeps its original service address and ingress. Its selector
  targets `app.kubernetes.io/instance=langfuse-v2`. This override is stored in
  the retained release's packaged chart, not merely a live patch.
- S3 bucket, salt, encryption key, NextAuth secret, and API credentials are
  preserved. S3 versioning is enabled. All migration PVs use `Retain`.

Do not run the old component installer against this deployment. It uses v1
values and could revive old writers. The installer and uninstaller now reject
operations when the migrated release exists.

## Recovery material

Private local directory:
`/Users/tracilim/Documents/langfuse-backups/20260914.4TCLA1`

Contains original Helm values/manifests/secrets, PostgreSQL dumps, migration
values, verification results, and the retained v1 chart package. Do not commit
these files: they contain credentials and user data.

Stopped-data EBS snapshots (2026-09-14):

| Store | Snapshot |
| --- | --- |
| PostgreSQL | `snap-09f301f346d1e316e` |
| ClickHouse | `snap-040c8903bdc6a60fd` |
| ZooKeeper | `snap-05e768fb014826435` |
| Redis | `snap-0881ffc7ca745c94d` |

The original volumes and databases are retained. Restoring them would omit
new writes after cutover; do not blindly roll back Helm or route traffic back.

## Verified copy baseline

All 72 PostgreSQL tables matched by row count and content checksum before v4
schema migration. All five ClickHouse data tables matched by deduplicated row
count and content checksum:

| Table | Rows |
| --- | ---: |
| traces | 292,799 |
| observations | 363,499 |
| scores | 3 |
| dataset_run_items_rmt | 0 |
| blob_storage_file_log | 665,525 |

## Compatibility

v4 runs in `dual` write mode with native OTel `dual_write`. Do not switch to
`events_only` until every producer and API consumer is migrated. Existing
LiteLLM callbacks use the legacy ingestion path. The new v4 observation view
can lag ingestion by approximately 10–15 minutes during dual write.

Historical backfill must run only after dual-write propagation is verified.
Keep old trace tables and the backfill scratch table; no archival cleanup is
authorized by this migration.

The first dual-write partition propagated successfully at 14:05 UTC on
2026-09-14. Historical backfill was enabled after that check. Root-span
backfill completed all six monthly partitions at 14:11:51 UTC. Observation
staging finished at 14:17:15 UTC; all 13 observation conversion parts and the
dataset-run stage finished at 14:27:39 UTC. The scratch-table cleanup stage
intentionally remains off. No migration failures were recorded.

Final source-to-v4 comparison: all **292,799 trace IDs** and **363,499
observation IDs** are present. Every observation's input/output and metadata
match; every trace's metadata matches. One trace output differs because the
ongoing migration Codex session continued after cutover:
`01a0a016-6998-7561-81ff-7d3f160f703b` advanced from event timestamp
`13:45:50.616` to `14:23:46.653` UTC. No unexplained differences remained.

## Integration checks

- Herdr tab `w9:tH`, agent `langfuse-codex-test`: two actual Codex TUI prompts
  returned the requested markers. Langfuse trace
  `01a0a02e-2c21-7281-9959-4e12b16de064` includes both outputs and the
  `codex-tui` user-agent; verified in the Langfuse browser UI.
- Open WebUI authenticated chat endpoint: trace
  `d77d00f7-5181-43c0-b460-05c84547853a` contains the test response.
- Open WebUI browser-submitted chat using `bedrock/gpt-6-astra`: trace
  `c9eca8d2-6bc5-4603-8e41-852d096f217b` contains the exact response;
  verified in both browser interfaces.
- Both Codex replies and both Open WebUI success markers were also verified
  in `events_full` after dual-write propagation, not only in legacy tables.
- Existing Open WebUI default `bedrock/amazon-nova-premier` is rejected by
  Bedrock because the model is Legacy. Its default was not changed.

Run the local safety check with:
`node components/o11y/langfuse/migration-guard.test.mjs`.

## AMP / AMG monitoring port

Monitoring account: `183124052465` (`AWS_PROFILE=monitoring`), AMP workspace
`ws-18f25b04-b19d-4151-afcf-fc795806904f`, AMG workspace `g-f66ac87de6`.
Source repository: `/Users/tracilim/Projects/genai-on-eks-observability`.

- `langfuse-worker-metrics` now selects `langfuse-v2` workers; the Terraform
  source matches the live service.
- AMP web/worker alerts now target `langfuse-v2-web` / `langfuse-v2-worker`.
- Dependency readiness covers the new PostgreSQL, ClickHouse and Keeper plus
  shared Redis, excluding archived v3 stores and completed version-probe jobs.
- AMG's Langfuse dashboard selectors and runbook commands are updated.
- All five Langfuse alerts evaluated `inactive` / `ok`; both probe series
  returned `1` through AMP directly and through AMG's data-source proxy.
- Existing thresholds, severity labels, rule names and Alertmanager/SNS
  routing are unchanged. No synthetic notification was sent.
