# DevOps Agent Space — Setup Guide

> After running `./deploy.sh`, follow these steps to connect DevOps Agent to your MCP servers.
> Run `bash scripts/show-setup-values.sh` at any time to get all values needed below.
> For the system architecture diagram, see the [Solution Architecture](../README.md#solution-architecture) section in the main README.

---

## Step 1: Create Agent Space

1. Open [AWS DevOps Agent console](https://console.aws.amazon.com/devops-agent/home)
2. Click **Create Agent Space +**
3. Fill in:
   - **Name:** `emr-spark-alert-reduction`
   - **AWS resource access:** Select **Auto-create a new AWS DevOps Agent role**
4. **Add tag filter:** Key: `devopsagent`, Value: `true`
5. **Enable Web App** (toggle on)
6. Click **Submit**

Wait for the Agent Space to become **Active** (~2 minutes).

---

## Step 2: Configure Amazon EKS Access

This lets DevOps Agent query your Amazon EKS cluster (pods, logs, events).

> **Recommendations for this setup:**
> 1. Create the dedicated access entry for the DevOps Agent IAM role — do not reuse a human user or a broad `system:masters` principal. Scope: view-only via `AmazonEKSViewPolicy`. Measurable improvement: eliminates long-lived cluster-admin exposure in favor of a service-scoped least-privilege principal.
> 2. After verification, restrict the access entry to specific namespaces if your agent workload only needs a subset — update the access scope via `--access-scope type=namespace,namespaces=emr-data-team-a`.
> 3. Enable Amazon EKS audit logging (if not already on) and monitor access entry changes via AWS CloudTrail.

1. In your Agent Space, go to **Capabilities** → **Cloud** → **Primary Source** → **Edit**
2. The console displays the DevOps Agent IAM role ARN — copy it
   - It looks like: `arn:aws:iam::<ACCOUNT_ID>:role/service-role/DevOpsAgentRole-AgentSpace-<ID>`
3. The console shows the exact commands to run — follow them, or use these:

```bash
# Replace with YOUR values
export AWS_REGION=us-west-2
export EKS_CLUSTER=emr-eks-karpenter
export AGENT_ROLE_ARN="<paste the role ARN from the console>"

# Grant DevOps Agent access to your Amazon EKS cluster
aws eks create-access-entry \
  --cluster-name $EKS_CLUSTER \
  --principal-arn "$AGENT_ROLE_ARN" \
  --region $AWS_REGION

aws eks associate-access-policy \
  --cluster-name $EKS_CLUSTER \
  --principal-arn "$AGENT_ROLE_ARN" \
  --policy-arn "arn:aws:eks::aws:cluster-access-policy/AmazonAIOpsAssistantPolicy" \
  --access-scope type=cluster \
  --region $AWS_REGION
```

4. Back in the console, click **Save**

> **"Already in use" error?** Safe to ignore — the access entry already exists.

---

## Step 3: Create Private Connection for SHS MCP

This creates a secure network path from DevOps Agent to your internal NLB of SHS MCP. 

**Get the values:**

```bash
# All values at once
bash scripts/show-setup-values.sh

# Or individually:

# VPC and subnets
aws eks describe-cluster --name emr-eks-karpenter --region $AWS_REGION \
  --query '{VPC: cluster.resourcesVpcConfig.vpcId, Subnets: cluster.resourcesVpcConfig.subnetIds}'

# Security group
aws ec2 describe-security-groups --region $AWS_REGION \
  --filters "Name=group-name,Values=dev-shs-mcp-private-connection-sg" \
  --query 'SecurityGroups[0].GroupId' --output text

# NLB hostname
kubectl get svc shs-mcp-mcp-apache-spark-history-server -n spark-history \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' && echo

# TLS certificate (copy the entire output including BEGIN/END lines)
kubectl get secret shs-mcp-tls -n spark-history -o jsonpath='{.data.tls\.crt}' | base64 -d
```

**In the console:**

1. Go to **Capability Providers** → **Private Connections** → **Create**
2. Fill in:

| Field | What to enter |
|-------|---------------|
| Name | `shs-mcp-private` |
| VPC where your resource is located | The VPC ID from the command above |
| Subnets | Select the subnets listed above |
| IP address type | IPv4 |
| Security groups associated with your connected resources | The SG ID from the command above (`dev-shs-mcp-private-connection-sg`). This SG has outbound TCP 18889 to your VPC CIDRs. |
| Host address | The NLB hostname from the command above |
| TCP port range | `18889` |
| Certificate | Paste the full PEM certificate from the command above (including `-----BEGIN CERTIFICATE-----` and `-----END CERTIFICATE-----` lines) |

3. Click **Create Connection**
4. Wait for status to change to **Completed** (~5-10 minutes)

> **Stuck in "Establishing"?** Check that the security group has outbound rules and the subnets have available IPs.

---

## Step 4: Register SHS MCP Server

This registers the Spark History Server MCP (18 tools) with DevOps Agent.

**Get the values:**

```bash
# Endpoint URL
NLB=$(kubectl get svc shs-mcp-mcp-apache-spark-history-server -n spark-history \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Endpoint: https://${NLB}:18889/mcp/"

# API key — stored in a Kubernetes Secret (never persisted in config.env or printed)
# Retrieve on demand when pasting into the DevOps Agent console:
API_KEY=$(kubectl get secret shs-mcp-apikey -n spark-history \
  -o jsonpath='{.data.api-key}' | base64 -d)
echo "API Key: retrieved (paste this into the DevOps Agent console)"
```

**To copy the API key for the DevOps Agent console:**

```bash
kubectl get secret shs-mcp-apikey -n spark-history \
  -o jsonpath='{.data.api-key}' | base64 -d; echo
```

Or run `bash scripts/show-setup-values.sh` to print all setup values.

**In the console:**

1. Go to **Capability Providers** → **MCP Server** → **Register**
2. Fill in:

| Field | What to enter |
|-------|---------------|
| Name | `spark-history-mcp` |
| Endpoint URL | `https://<NLB-hostname>:18889/mcp/` — **trailing slash required** |
| Connect via Private Connection | ✅ Check this, select `shs-mcp-private` |
| Auth type | API Key |
| API Key header | `x-api-key` |
| API Key value | the output of the kubectl command above |

> **Note:** The API key is auto-generated by `deploy.sh` and stored only in a Kubernetes Secret (`shs-mcp-apikey`) in the `spark-history` namespace. It is never written to `config.env`, printed to stdout, or persisted on disk. On redeploy, the existing key is reused so your DevOps Agent console registration remains valid.

3. Click **Submit** — DevOps Agent validates the connection

> **Registration timeout?** Check: Private Connection is **Completed**, endpoint has trailing `/mcp/`, SG rules are correct.

### Associate SHS MCP with your Agent Space

After both MCP servers are registered (Steps 4 + 5), associate them with your Agent Space:

1. Go to your **Agent Space** → **MCP Servers** tab
2. Click **Associate MCP Server**
3. Select `spark-history-mcp` → **Select all tools** (18 tools) → **Apply**
4. Repeat: **Associate MCP Server** → select `emr-spark-runbook-mcp` → **Select all tools** (3 tools) → **Apply**

You should now see 21 tools total (18 SHS + 3 Runbook) in your Agent Space.

---

## Step 5: Register Runbook MCP Server

This registers the Runbook MCP (3 tools) that searches Amazon Bedrock Knowledge Base.

**Get the values:**

```bash
# Amazon Bedrock AgentCore Runtime ARN
aws cloudformation describe-stacks --stack-name AgentCore-runbookmcp-default --region $AWS_REGION \
  --query "Stacks[0].Outputs[?OutputKey=='RuntimeArn'].OutputValue" --output text

# Cognito credentials
POOL_ID=$(aws cognito-idp list-user-pools --max-results 20 --region $AWS_REGION \
  --query "UserPools[?Name=='emr-spark-mcp-pool'].Id" --output text)

CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "$POOL_ID" --region $AWS_REGION \
  --query "UserPoolClients[?ClientName=='devops-agent-client'].ClientId" --output text)

CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client --user-pool-id "$POOL_ID" \
  --client-id "$CLIENT_ID" --region $AWS_REGION \
  --query "UserPoolClient.ClientSecret" --output text)

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TOKEN_URL="https://emr-spark-mcp-${ACCOUNT_ID}.auth.${AWS_REGION}.amazoncognito.com/oauth2/token"

echo "Runtime ARN : (from first command above)"
echo "Client ID   : $CLIENT_ID"
echo "Client Secret: $CLIENT_SECRET"
echo "Token URL   : $TOKEN_URL"
```

**In the console:**

1. Go to **Capability Providers** → **MCP Server** → **Register**
2. Fill in:

| Field | What to enter |
|-------|---------------|
| Name | `emr-spark-runbook-mcp` |
| Endpoint URL | The Runtime ARN from the command above |
| Auth type | OAuth Client Credentials |
| Client ID | From the command above |
| Client Secret | From the command above |
| Token Exchange URL | The Token URL from the command above |
| Scope | `openid` |

3. Click **Submit**

> **Auth fails?** Verify the Token URL uses the Cognito hosted UI domain (`*.auth.*.amazoncognito.com`), not the `cognito-idp` API URL.

After both MCP servers are registered, go back to Step 4's "Associate SHS MCP with your Agent Space" section above to associate both servers with your Agent Space.

---

## Verify Everything Works

1. Submit a baseline Spark job:

```bash
cd fault-injection && chmod +x *.sh
./rollback-submit-good-job.sh
```

2. Check it appears in Spark History Server:

```bash
kubectl exec -n spark-history deploy/spark-history-server -- \
  curl -s http://localhost:18080/api/v1/applications
```

3. Open the **DevOps Agent Web App** (click **Operator Access** in your Agent Space)
4. Start an investigation to confirm the agent can reach both MCP servers

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Private Connection stuck in "Establishing" | Check subnet IP availability and VPC Lattice quotas |
| MCP registration timeout | Check SG outbound rules cover ALL VPC CIDRs on port 18889 |
| 401 Unauthorized on SHS MCP | Retrieve the current key via kubectl and compare: `kubectl get secret shs-mcp-apikey -n spark-history -o jsonpath='{.data.api-key}' | base64 -d` |
| Runbook MCP auth fails | Verify Token URL uses `*.auth.*.amazoncognito.com` domain |
| Agent can't access Amazon EKS | Complete Step 2 — run the access entry commands |
| Endpoint URL rejected | Ensure trailing slash: `/mcp/` not `/mcp` |
|  Amazon Bedrock AgentCore| Amazon Bedrock AgentCore deploys to us-east-1. Check: `aws cloudformation describe-stacks --stack-name AgentCore-runbookmcp-default --region us-east-1` |
| `search_runbooks` returns 0 results | AOSS network policy may have reset. Run: `bash scripts/scale-up.sh` |

---

## Security Notes

See [Security Considerations](SECURITY_CONSIDERATIONS.md) for shared responsibility, encryption, access logging, key management, and scan attestation details.
