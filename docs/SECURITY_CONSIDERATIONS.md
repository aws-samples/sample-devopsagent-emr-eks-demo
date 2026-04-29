## Security Considerations

This is sample code for educational use. Review and adjust every security setting before any production deployment. Vulnerabilities should be reported per [SECURITY.md](../SECURITY.md).

### Shared responsibility

| Component | AWS manages | You are responsible for |
|---|---|---|
| Amazon EKS | Control plane, node-group image patching | Kubernetes RBAC (least-privilege role bindings), pod-level security context (`runAsNonRoot`, `readOnlyRootFilesystem`, seccomp profile), node security groups, access entries with AmazonEKSViewPolicy (not system:masters), audit logging |
| Amazon EMR on Amazon EKS | Managed Spark runtime | Job permissions, spark-submit config, execution role scoping |
| Amazon S3 | Durability and infrastructure | Bucket policies (HTTPS-only, least-privilege), Block Public Access (all four flags: BlockPublicAcls, BlockPublicPolicy, IgnorePublicAcls, RestrictPublicBuckets), encryption choice (SSE-S3 / SSE-KMS / SSE-C), object lifecycle rules, versioning, server access logging. This sample configures BPA (all four flags), SSE-S3 (AES-256) encryption, HTTPS-only bucket policy (`aws:SecureTransport` Deny), versioning enabled, and server access logging via `infrastructure/template.yaml`. |
| Amazon Bedrock | Foundation model runtime | Prompt content, knowledge-base contents, output handling |
| Amazon OpenSearch Serverless | Infrastructure + service encryption | Access policies, network policies, data content |
| Amazon VPC Lattice | Lattice service plane | Security-group rules, resource-gateway config, TLS certificates |
| Amazon Cognito | Identity service | User-pool config, client secret storage, token TTL |
| IAM | Policy evaluation engine | Policy design, least-privilege scoping, periodic review |

### API keys and passwords

The Spark History Server MCP endpoint is protected by an API key that `deploy-shs-mcp-private.sh` generates on first deploy (`openssl rand -hex 32`) and stores in a Kubernetes Secret (`shs-mcp-apikey`) in the `spark-history` namespace. The key is never written to `config.env`, printed to stdout, or persisted on disk. Retrieve it on demand when pasting into the DevOps Agent console:

```bash
kubectl get secret shs-mcp-apikey -n spark-history \
  -o jsonpath='{.data.api-key}' | base64 -d
```

The Runbook MCP uses OAuth 2.0 Client Credentials via Amazon Cognito — `deploy-mcp-server.sh` creates the user pool and app client; Cognito auto-generates the client ID and secret. Retrieve them via the commands in `docs/AGENT_SPACE_SETUP.md`.

Compensating controls in this sample:

- **No credential logging:** neither the SHS MCP API key nor the Cognito secrets are printed to stdout or written to files. Retrieval happens on demand via `kubectl` or `aws` commands at registration time.
- **Source control protection:** `config.env` is in `.gitignore` and contains no credentials. `config.env.template` has only cluster identifiers (placeholder).
- **Credential scope:** The SHS MCP API key is mounted only by the nginx sidecar pod. The Cognito client secret is validated only by AWS Cognito.
- **Idempotent key handling:** On redeploy, `deploy-shs-mcp-private.sh` reuses the existing Kubernetes Secret rather than generating a new key, preserving the DevOps Agent console registration.
- **Design choice:** This sample stores credentials in Kubernetes Secrets and AWS Cognito directly. For production, consider migrating to AWS Secrets Manager with IAM-scoped `secretsmanager:GetSecretValue`.

### TLS certificates

The `deploy-shs-mcp-private.sh` script generates a self-signed RSA-2048 certificate with a 365-day validity for the internal NLB. This is acceptable for an internal demo endpoint that never leaves the VPC. For production use: provision a certificate from AWS Certificate Manager (or AWS Private CA for internal use), attach it to the NLB, and implement rotation before expiry. Monitor expiry via `aws acm list-certificates`.

### Key management strategy

This sample is intended for short-lived demo/learning deployments. Tear down all resources with `destroy.sh` when done. If you adapt any part for longer-lived or production use, apply these key management best practices:

| Key type | Best practice |
|---|---|
| SHS MCP API key | Rotate by deleting the `shs-mcp-apikey` Kubernetes Secret and re-running `deploy-shs-mcp-private.sh`. Update the DevOps Agent console with the new key. For production, store in AWS Secrets Manager. |
| TLS certificate | Replace self-signed with AWS Certificate Manager (ACM); enable auto-renewal; alert on `DaysToExpiry` |
| Cognito client secret | Rotate via Cognito console or CLI; update AWS DevOps Agent MCP registration after rotation |
| Amazon S3 / Amazon OpenSearch Serverless encryption | AWS-managed — no action required |

### Data classification

| Data | Where it lives | Sensitivity | Encryption | Retention |
|---|---|---|---|---|
| Spark event logs | Amazon S3 (`spark-events/`) | Low — operational metadata | SSE-S3 (AES-256) | Until stack deletion |
| Runbook YAMLs | Amazon S3 (`runbooks/`) | Low — public-style guidance | SSE-S3 (AES-256) | Until stack deletion |
| Vector embeddings | Amazon OpenSearch Serverless | Low — derived from runbooks | AWS-owned key | Until collection deletion |
| S3 access logs | Amazon S3 (logging bucket) | Medium — operational auditing | SSE-S3 (AES-256) | Until stack deletion |
| Cognito client secrets | Amazon Cognito (internal) | High — authentication material | Service-side (AWS-managed) | Rotate periodically |
| SHS MCP API key | Kubernetes Secret (`shs-mcp-apikey`) | High — authentication material | etcd encryption (Amazon EKS-managed) | Rotate by deleting the Secret and re-running `deploy-shs-mcp-private.sh` |

### IAM access review

IAM policies in this sample are scoped to specific resources: Amazon CloudWatch Logs to `/emr-on-eks/*` and `/aws/emr-containers/*` log groups, Amazon S3 write to specific bucket prefixes (`spark-events/`, `logs/`, `output/`, `jobs/`), Amazon OpenSearch Serverless to specific actions with account conditions, and Amazon Bedrock to specific foundation model and knowledge base ARNs. The following review steps are for ongoing maintenance if you keep the environment running beyond the initial demo:

- enable [AWS CloudTrail](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html) data events for role usage — provides 100% audit coverage of who assumed each role and what actions they performed.
- run [AWS IAM Access Analyzer](https://docs.aws.amazon.com/IAM/latest/UserGuide/access-analyzer-policy-generation.html) on each role and remove actions it flags as unused — measurable improvement: policy shrinks to only actions actually exercised.
- `aws iam list-role-policies --role-name <role>` and confirm each policy is still needed. Delete roles that have not been used in 90 days.
- **Cleanup:** `destroy.sh` removes the inline policies added by `patch-emr-role.sh`. Verify with `aws iam list-role-policies --role-name <your-emr-role>` after teardown.

### Third-party components

This sample uses third-party open-source software under Apache 2.0 and BSD 2-Clause licenses. If you redistribute or create derivative works, follow the attribution requirements of each upstream license.

| Component | Version | License |
|---|---|---|
| [kubeflow/mcp-apache-spark-history-server](https://github.com/kubeflow/mcp-apache-spark-history-server) | v0.1.5 | Apache 2.0 |
| [Apache Spark History Server](https://spark.apache.org/) | 3.5.x | Apache 2.0 |
| [Nginx](https://nginx.org/) | 1.25+ | BSD 2-Clause |

### Security scanning

All executable code in this repository was scanned on 2026-04-19.

| Tool | Scope | Findings |
|---|---|---|
| [Bandit](https://bandit.readthedocs.io/) v1.8+ | Python (`mcp_server/`, `infrastructure/lambda/`, `sample-jobs/`) | 0 issues; 7 suppressed with `# nosec` + inline justification |
| [ShellCheck](https://www.shellcheck.net/) v0.9.0 | Bash (`scripts/`, `deploy.sh`, `destroy.sh`, `fault-injection/`) | 0 errors, 0 critical/high; info/style only (SC1091 external source, SC2001 style preference) |
| [cfn-guard](https://github.com/aws-cloudformation/cloudformation-guard) | `infrastructure/template.yaml` | 0 findings after remediation (S3 BPA, bucket policies, logging added) |
| [Checkov](https://www.checkov.io/) | `infrastructure/template.yaml` | 0 findings after remediation (CKV_AWS_18/26/53-56 resolved) |
| Manual review | Credential handling in deployment scripts | Reviewed: API key is auto-generated, stored only in a Kubernetes Secret (`shs-mcp-apikey`), and never written to files, environment variables, or stdout. Retrieved on demand via `kubectl` at console registration time. |

### AI/ML security controls

The Runbook MCP server passes user queries to the Amazon Bedrock Retrieve API, which applies its own input guardrails. The MCP tools do not execute arbitrary code or modify infrastructure — they are read-only (search runbooks, get runbook, list categories). Specific controls:

- **Input validation:** Query strings are passed to Amazon Bedrock Retrieve API which validates format server-side. Runbook IDs are Amazon S3 object keys scoped to the `runbooks/` prefix by the tool implementation.
- **Output filtering:** Amazon Bedrock Knowledge Base returns ranked text passages from the indexed runbooks. No model-generated content is returned — only retrieved passages from your own runbook dataset.
- **Monitoring:** Enable CloudTrail data events for Amazon Bedrock to log all Retrieve and InvokeModel calls. Set Amazon CloudWatch alarms on `bedrock:ThrottlingException` and error-rate metrics for anomaly detection.
- **Model access:** The IAM policy scopes `bedrock:InvokeModel` to specific foundation model ARNs (Titan Embed, Claude) — not a wildcard across all models.


### Residual risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| SHS MCP API key leaked | Low — stored in K8s Secret + env var | Medium — unauthorized read of Spark job metadata | Rotate via `openssl rand -hex 32`; restrict secret RBAC to the nginx sidecar pod only |
| Runbook content tampering | Low — bucket policy + BPA + versioning | Medium — agent acts on malicious guidance | Enable S3 versioning (already on); audit uploads via S3 access logs; restrict `s3:PutObject` to CI/CD role |
| Amazon EMR execution role scope | Low — scoped to specific log groups + bucket prefixes | Low — write limited to `spark-events/`, `logs/`, `output/`, `jobs/` prefixes | Further tighten with IAM Access Analyzer after 30 days of observed usage |
| Self-signed TLS expires | Medium — 365-day validity | High — SHS MCP endpoint unreachable | Replace with AWS Certificate Manager (ACM) cert for any long-lived use; monitor expiry with CloudWatch alarms |
| Cognito test user credentials reused | Low — per-deployment generation | Low — test user has no runtime impact on AWS DevOps Agent OAuth flow | Delete the test user after initial verification; AWS DevOps Agent uses client-credentials flow in production |

