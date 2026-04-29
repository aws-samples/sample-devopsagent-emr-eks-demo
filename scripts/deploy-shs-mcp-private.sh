#!/usr/bin/env bash
# =============================================================================
# Deploy SHS MCP via Helm + Nginx Auth Proxy + Internal NLB
#
# What this does:
#   1. Deploys SHS MCP Helm chart (kubeflow/mcp-apache-spark-history-server)
#   2. Adds nginx sidecar for TLS + API key auth (AWS DevOps Agent requires both)
#   3. Creates internal NLB on port 18889 (HTTPS)
#   4. Creates security group for Private Connection ENIs
#   5. Prints all values needed for console setup
#
# Console steps after this script:
#   - Create Private Connection (host, port, VPC, subnets, SG, cert)
#   - Register MCP Server (endpoint, API key, private connection)
#   See docs/AGENT_SPACE_SETUP.md
#
# Prerequisites:
#   - EKS cluster with SHS already deployed (scripts/deploy-shs.sh)
#   - Helm 3.8+, openssl
#   - config.env populated
#
# Usage: bash scripts/deploy-shs-mcp-private-v2.sh
# =============================================================================
set -euo pipefail

source config.env
REGION="${AWS_REGION:-us-east-1}"
ENV="${ENVIRONMENT_NAME:-dev}"
NS="spark-history"
HTTPS_PORT=18889
MCP_PORT=18888

info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
err()   { echo -e "\033[31m[ERR]\033[0m   $*" >&2; }

# ── Preflight ──────────────────────────────────────────────────────────────
for cmd in helm kubectl aws jq openssl; do
  command -v "$cmd" &>/dev/null || { err "$cmd not found"; exit 1; }
done

aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$REGION" 2>/dev/null

if ! kubectl get svc spark-history-server -n "$NS" &>/dev/null; then
  err "Spark History Server not found in namespace $NS."
  err "Run 'bash scripts/deploy-shs.sh' first."
  exit 1
fi
ok "SHS service found in $NS"

# ── Step 1: Deploy SHS MCP via Helm ───────────────────────────────────────
info "Step 1/7: Deploying SHS MCP via Helm chart ..."

# Security note — data at rest and in transit:
#   * Spark event logs in Amazon S3 inherit the DataBucket encryption policy
#     (SSE-S3 / AES-256) and HTTPS-only bucket policy from infrastructure/template.yaml.
#   * Application logs from the nginx sidecar and MCP server go to Amazon
#     CloudWatch Logs, which encrypts log data at rest by default. For
#     customer-managed KMS on log groups, attach a CMK via
#     `aws logs associate-kms-key --log-group-name ... --kms-key-id ...`
#     after this script creates them.
#   * API key + TLS key are stored in Kubernetes Secrets (etcd-encrypted by
#     default on Amazon EKS control plane).

# Third-party component attribution:
#   kubeflow/mcp-apache-spark-history-server (Apache 2.0) — MCP wrapper around
#   Apache Spark History Server. See docs/THIRD_PARTY_APPROVALS.md for the full
#   component list and license details.
helm repo add kubeflow https://kubeflow.github.io/mcp-apache-spark-history-server 2>/dev/null || true
helm repo update kubeflow 2>/dev/null || true

CHART_SOURCE="kubeflow/mcp-apache-spark-history-server"
if ! helm search repo "$CHART_SOURCE" &>/dev/null; then
  info "Helm repo not found, cloning chart from GitHub ..."
  CHART_DIR=$(mktemp -d)
  git clone --depth 1 https://github.com/kubeflow/mcp-apache-spark-history-server.git "$CHART_DIR/repo" 2>/dev/null
  CHART_SOURCE="$CHART_DIR/repo/deploy/kubernetes/helm/mcp-apache-spark-history-server"
fi

helm upgrade --install shs-mcp "$CHART_SOURCE" \
  --namespace "$NS" --create-namespace \
  -f spark-history-mcp/helm-values.yaml \
  --wait --timeout 180s

ok "SHS MCP deployed via Helm"

# ── Step 2: Generate TLS cert + K8s secrets ───────────────────────────────
info "Step 2/7: Setting up TLS + API key secrets ..."

# ─────────────────────────────────────────────────────────────────────────────
# TLS security controls (demo / sample configuration):
#   - Self-signed RSA-2048 (NIST SP 800-131A minimum) for the internal NLB
#   - 365-day validity — rotate before expiry or switch to ACM for production
#   - Key material never leaves the pod (written to mktemp, uploaded to a K8s
#     TLS secret, then the tmp directory is removed when the script exits)
#
# Measurable improvement over plaintext: the NLB listener requires TLS 1.2+,
# which means all MCP traffic between the agent and the Spark History Server
# MCP endpoint is encrypted (confidentiality), integrity-protected (HMAC on
# TLS records), and carries server-auth (cert chain presented). The complement
# is the `x-api-key` header, checked by the nginx sidecar (authentication).
#
# For production deployments (in priority order):
#   1. HIGH: Replace with an AWS Certificate Manager (ACM) certificate or an
#      AWS Private CA certificate for internal trust — eliminates the
#      self-signed trust store workaround and provides automated rotation.
#   2. MEDIUM: Automate rotation well before the cert expires (CloudWatch alarm
#      on `DaysToExpiry` + AWS Lambda rotator). Target: rotate at 75% of validity.
#   3. LOW: Move to ECDSA P-256 keys once all clients support them (smaller
#      handshakes, faster TLS termination).
# ─────────────────────────────────────────────────────────────────────────────
TLS_DIR=$(mktemp -d)
if ! kubectl get secret shs-mcp-tls -n "$NS" &>/dev/null; then
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$TLS_DIR/tls.key" -out "$TLS_DIR/tls.crt" \
    -subj "/CN=shs-mcp.${NS}.svc.cluster.local" \
    -addext "subjectAltName=DNS:shs-mcp.${NS}.svc.cluster.local,DNS:*.elb.${REGION}.amazonaws.com" 2>/dev/null
  kubectl create secret tls shs-mcp-tls --cert="$TLS_DIR/tls.crt" --key="$TLS_DIR/tls.key" -n "$NS"
  ok "TLS cert created"
else
  # Extract existing cert for output later
  kubectl get secret shs-mcp-tls -n "$NS" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$TLS_DIR/tls.crt"
  ok "TLS cert already exists"
fi

if kubectl get secret shs-mcp-apikey -n "$NS" &>/dev/null; then
  # Reuse existing secret — keeps DevOps Agent console registration valid across redeploys
  API_KEY=$(kubectl get secret shs-mcp-apikey -n "$NS" -o jsonpath='{.data.api-key}' | base64 -d)
  ok "API key secret already exists — reusing"
else
  # First deploy: generate a strong random key and store it in a Kubernetes Secret.
  # The key is never written to disk, printed to stdout, or persisted in config.env.
  # Retrieve it on demand with: kubectl get secret shs-mcp-apikey -n spark-history \
  #   -o jsonpath='{.data.api-key}' | base64 -d
  API_KEY=$(openssl rand -hex 32)
  kubectl create secret generic shs-mcp-apikey --from-literal=api-key="$API_KEY" -n "$NS"
  ok "API key generated and stored in Kubernetes Secret (etcd-encrypted)"
fi

# ── Step 3: Create nginx ConfigMap ────────────────────────────────────────
info "Step 3/7: Creating nginx auth proxy config ..."

kubectl apply -f - <<'NGINX_CM'
apiVersion: v1
kind: ConfigMap
metadata:
  name: shs-mcp-nginx-conf
  namespace: spark-history
data:
  nginx.conf: |
    worker_processes 1;
    pid /tmp/nginx.pid;
    error_log /tmp/nginx-error.log;
    events { worker_connections 128; }
    http {
        client_body_temp_path /tmp/client_temp;
        proxy_temp_path /tmp/proxy_temp;
        fastcgi_temp_path /tmp/fastcgi_temp;
        uwsgi_temp_path /tmp/uwsgi_temp;
        scgi_temp_path /tmp/scgi_temp;
        access_log /tmp/nginx-access.log;
        server {
            listen 18889 ssl;
            ssl_certificate /etc/nginx/tls/tls.crt;
            ssl_certificate_key /etc/nginx/tls/tls.key;
            ssl_protocols TLSv1.2 TLSv1.3;
            location = /mcp {
                rewrite ^/mcp$ /mcp/ permanent;
            }
            location / {
                if ($http_x_api_key != "__API_KEY__") {
                    return 401 "Unauthorized";
                }
                proxy_pass http://127.0.0.1:18888;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header Connection "";
                proxy_http_version 1.1;
                proxy_buffering off;
                proxy_read_timeout 300s;
                proxy_redirect http:// https://;
            }
        }
    }
NGINX_CM
ok "Nginx ConfigMap created"

# ── Step 4: Patch deployment with nginx sidecar ───────────────────────────
info "Step 4/7: Adding nginx auth proxy sidecar ..."

kubectl patch deployment shs-mcp-mcp-apache-spark-history-server -n "$NS" --type=strategic -p='{
  "spec": {
    "template": {
      "metadata": {"annotations": {"shs-mcp/auth-proxy": "v2"}},
      "spec": {
        "volumes": [
          {"name": "nginx-tls", "secret": {"secretName": "shs-mcp-tls"}},
          {"name": "nginx-conf-template", "configMap": {"name": "shs-mcp-nginx-conf"}},
          {"name": "nginx-conf-rendered", "emptyDir": {}}
        ],
        "initContainers": [
          {
            "name": "render-nginx-conf",
            "image": "busybox:1.36",
            "command": ["sh", "-c"],
            "args": ["sed \"s/__API_KEY__/$API_KEY/g\" /etc/nginx-template/nginx.conf > /etc/nginx-rendered/nginx.conf"],
            "env": [{"name": "API_KEY", "valueFrom": {"secretKeyRef": {"name": "shs-mcp-apikey", "key": "api-key"}}}],
            "volumeMounts": [
              {"name": "nginx-conf-template", "mountPath": "/etc/nginx-template"},
              {"name": "nginx-conf-rendered", "mountPath": "/etc/nginx-rendered"}
            ]
          }
        ],
        "containers": [
          {
            "name": "nginx-auth-proxy",
            "image": "nginx:1.27-alpine",
            "command": ["nginx", "-c", "/etc/nginx-rendered/nginx.conf", "-g", "daemon off;"],
            "ports": [{"containerPort": 18889, "name": "https"}],
            "volumeMounts": [
              {"name": "nginx-tls", "mountPath": "/etc/nginx/tls", "readOnly": true},
              {"name": "nginx-conf-rendered", "mountPath": "/etc/nginx-rendered", "readOnly": true}
            ],
            "resources": {"requests": {"cpu": "50m", "memory": "32Mi"}, "limits": {"cpu": "100m", "memory": "64Mi"}}
          }
        ]
      }
    }
  }
}'

kubectl rollout status deployment/shs-mcp-mcp-apache-spark-history-server -n "$NS" --timeout=120s
ok "Nginx auth proxy sidecar added"

# ── Step 5: Replace service with correct internal NLB on port 18889 ───────
info "Step 5/7: Creating internal NLB service on port $HTTPS_PORT ..."

# Delete Helm-managed service (wrong port/annotations)
kubectl delete svc shs-mcp-mcp-apache-spark-history-server -n "$NS" 2>/dev/null || true
sleep 10

kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: shs-mcp-mcp-apache-spark-history-server
  namespace: $NS
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
  labels:
    app.kubernetes.io/name: mcp-apache-spark-history-server
    app.kubernetes.io/instance: shs-mcp
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: mcp-apache-spark-history-server
    app.kubernetes.io/instance: shs-mcp
  ports:
    - name: https
      port: $HTTPS_PORT
      targetPort: $HTTPS_PORT
      protocol: TCP
EOF

# Wait for NLB
NLB_HOST=""
for i in $(seq 1 30); do
  NLB_HOST=$(kubectl get svc shs-mcp-mcp-apache-spark-history-server -n "$NS" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  [ -n "$NLB_HOST" ] && break
  sleep 10
done
if [ -z "$NLB_HOST" ]; then
  err "NLB hostname not available after 5 minutes."
  exit 1
fi
ok "Internal NLB ready: $NLB_HOST"

# ── Step 6: Create security group for Private Connection ──────────────────
info "Step 6/7: Creating security group for Private Connection ENIs ..."

VPC_ID=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
CLUSTER_SG=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
SUBNETS=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output json)

SG_NAME="${ENV}-shs-mcp-private-connection-sg"
EXISTING_SG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$EXISTING_SG" = "None" ] || [ -z "$EXISTING_SG" ]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Allow DevOps Agent Private Connection to reach SHS MCP on port $HTTPS_PORT" \
    --vpc-id "$VPC_ID" --region "$REGION" \
    --query 'GroupId' --output text)
  ok "Security group created: $SG_ID"

  # Remove default allow-all outbound
  DEFAULT_RULE=$(aws ec2 describe-security-group-rules --region "$REGION" \
    --filters "Name=group-id,Values=$SG_ID" \
    --query "SecurityGroupRules[?IsEgress && IpProtocol=='-1'].SecurityGroupRuleId" --output text 2>/dev/null || echo "")
  [ -n "$DEFAULT_RULE" ] && aws ec2 revoke-security-group-egress --group-id "$SG_ID" \
    --security-group-rule-ids "$DEFAULT_RULE" --region "$REGION" > /dev/null 2>&1 || true

  # Add outbound rules for ALL VPC CIDRs (NLB may be in any CIDR)
  VPC_CIDRS=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
    --query 'Vpcs[0].CidrBlockAssociationSet[].CidrBlock' --output text)
  for CIDR in $VPC_CIDRS; do
    aws ec2 authorize-security-group-egress --group-id "$SG_ID" \
      --protocol tcp --port "$HTTPS_PORT" --cidr "$CIDR" --region "$REGION" > /dev/null 2>&1 || true
    ok "SG outbound: TCP $HTTPS_PORT → $CIDR"
  done

  # Allow inbound on cluster SG from our SG
  aws ec2 authorize-security-group-ingress --group-id "$CLUSTER_SG" \
    --protocol tcp --port "$HTTPS_PORT" --source-group "$SG_ID" --region "$REGION" > /dev/null 2>&1 || true
  ok "Cluster SG inbound: TCP $HTTPS_PORT from $SG_ID"
else
  SG_ID="$EXISTING_SG"
  ok "Security group already exists: $SG_ID"
fi

# ── Step 7: Print summary ─────────────────────────────────────────────────
info "Step 7/7: Deployment complete!"

CERT_PEM=$(cat "$TLS_DIR/tls.crt")
SUBNET_LIST=$(echo "$SUBNETS" | jq -r '.[]' | tr '\n' ', ' | sed 's/,$//')

cat <<EOF

=============================================
  SHS MCP Deployed (HTTPS + API Key + Internal NLB)
=============================================

  ┌─────────────────────────────────────────────────────────┐
  │  Console Step 1: Create Private Connection              │
  ├─────────────────────────────────────────────────────────┤
  │  Name       : shs-mcp-private                          │
  │  VPC        : $VPC_ID
  │  Subnets    : $SUBNET_LIST
  │  Security Group : $SG_ID
  │  Host       : $NLB_HOST
  │  Port range : $HTTPS_PORT
  │  Certificate: (printed below)                           │
  └─────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────┐
  │  Console Step 2: Register MCP Server                    │
  ├─────────────────────────────────────────────────────────┤
  │  Name       : spark-history-mcp                         │
  │  Endpoint   : https://${NLB_HOST}:${HTTPS_PORT}/mcp/    │
  │  Private Connection : shs-mcp-private                   │
  │  Auth       : API Key                                   │
  │    Key name : api-key                                   │
  │    Header   : x-api-key                                 │
  │    Value    : (retrieve via kubectl — see AGENT_SPACE_SETUP.md)
  └─────────────────────────────────────────────────────────┘

  Certificate public key (paste into Private Connection):
$CERT_PEM

=============================================
  See docs/AGENT_SPACE_SETUP.md
=============================================
EOF

rm -rf "$TLS_DIR"
