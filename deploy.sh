#!/usr/bin/env bash
# =============================================================================
# CloudKitchen — ONE-COMMAND DEPLOY (3-repo, EKS-only, CloudFront → NLB)
#
#   ./deploy.sh
#
# Repos cloned SIDE BY SIDE: cloudkitchen-app / cloudkitchen-infra /
# cloudkitchen-gitops (run this from cloudkitchen-gitops).
#
# Flow:
#   1. terraform apply (infra; CloudFront has no API origin on this first pass)
#   2. build + push the 4 BACKEND images to ECR
#   3. build the React SPA and sync it to the frontend S3 bucket
#   4. install the platform (kgateway, ESO, ArgoCD, Prometheus/Grafana) + ArgoCD app
#   5. wait for the kgateway NLB, then a SECOND apply with
#      -var=eks_api_origin=<nlb> so CloudFront forwards /api and /auth to it,
#      then invalidate CloudFront
#
# Result: the entire app is reachable at the single CloudFront HTTPS URL
#   (CloudFront → S3 for the SPA, CloudFront → NLB → kgateway for /api and /auth).
#
# Prereqs: terraform, aws, kubectl, docker (running), npm, git. helm auto-installs.
# =============================================================================
set -euo pipefail

REGION="ap-south-1"
CLUSTER="cloudkitchen-eks"
ACCOUNT="256603361470"
ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
GITOPS="$(cd "$(dirname "$0")" && pwd)"
INFRA="$GITOPS/../cloudkitchen-infra"
APP="$GITOPS/../cloudkitchen-app"

# GitHub org that hosts the 3 repos (override with GIT_ORG=... ./deploy.sh).
GIT_ORG="${GIT_ORG:-Cloudkitchen007}"

echo "Preflight checks..."
for t in terraform aws kubectl docker npm git; do command -v "$t" >/dev/null || { echo "ERROR: $t not installed."; exit 1; }; done
docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not running."; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "ERROR: AWS credentials not configured (run 'aws configure')."; exit 1; }

# --- Auto-clone the sibling repos if missing (so this works on a fresh laptop) -
clone_if_missing() {
  [ -d "$2" ] || { echo "Cloning $1 → $2"; git clone "https://github.com/$GIT_ORG/$1.git" "$2"; }
}
clone_if_missing cloudkitchen-infra "$INFRA"
clone_if_missing cloudkitchen-app   "$APP"

# --- Ensure terraform.tfvars exists (gitignored secrets). Generate it from env -
# vars on a fresh machine: HF_API_TOKEN is required; SLACK_WEBHOOK_URL optional.
if [ ! -f "$INFRA/terraform.tfvars" ]; then
  [ -n "${HF_API_TOKEN:-}" ] || { echo "ERROR: no $INFRA/terraform.tfvars and HF_API_TOKEN env var not set.
  Set it once:  export HF_API_TOKEN=hf_xxx   (free token: huggingface.co/settings/tokens)
  Optional:     export SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...  (for alerts)"; exit 1; }
  echo "Generating $INFRA/terraform.tfvars from env vars..."
  {
    echo "hf_api_token = \"$HF_API_TOKEN\""
    [ -n "${SLACK_WEBHOOK_URL:-}" ] && echo "slack_webhook_url = \"$SLACK_WEBHOOK_URL\""
  } > "$INFRA/terraform.tfvars"
fi

# ensure helm
if ! command -v helm >/dev/null 2>&1 && [ ! -x "$HOME/bin/helm.exe" ]; then
  echo "Installing helm locally..."
  curl -fsSL https://get.helm.sh/helm-v3.16.3-windows-amd64.zip -o /tmp/helm.zip
  unzip -oq /tmp/helm.zip -d /tmp && mkdir -p "$HOME/bin" && cp /tmp/windows-amd64/helm.exe "$HOME/bin/helm.exe"
fi
export PATH="$HOME/bin:$PATH"

echo "######## 1/5  Terraform apply (infra) ########"
echo "--- bootstrap remote state (S3 + DynamoDB) ---"
( cd "$INFRA/bootstrap" && terraform init -input=false && terraform apply -auto-approve )
cd "$INFRA"
terraform init -input=false
terraform apply -auto-approve

echo "######## 2/5  Build + push BACKEND images to ECR ########"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"
build() { echo "--- $1 ---"; docker build -t "$ECR/$2:latest" "$APP/$1"; docker push "$ECR/$2:latest"; }
build menu-service   cloudkitchen-menu-repo
build order-service  cloudkitchen-order-repo
build auth-service   cloudkitchen-auth-repo
build ai-recommender cloudkitchen-ai-repo

echo "######## 3/5  Build React SPA + sync to S3 ########"
FRONTEND_BUCKET="$(terraform -chdir="$INFRA" output -raw frontend_bucket_name)"
# Testimonials upload talks to API Gateway directly; everything else uses
# RELATIVE /api paths served by CloudFront → NLB (same origin).
API_GW="$(terraform -chdir="$INFRA" output -raw api_gateway_url 2>/dev/null || echo "")"
( cd "$APP/frontend" && npm install && REACT_APP_API_GATEWAY_URL="$API_GW" npm run build )
aws s3 sync "$APP/frontend/build/" "s3://$FRONTEND_BUCKET" --delete

echo "######## 4/5  Platform + deploy app via ArgoCD ########"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
bash "$GITOPS/bootstrap/install.sh"
kubectl apply -f "$GITOPS/argocd/project.yaml"
kubectl apply -f "$GITOPS/argocd/application.yaml"

echo "######## 5/5  Wire CloudFront → EKS NLB ########"
# Delegated to the idempotent wire-cloudfront.sh: it waits up to 10 min for the
# NLB and FAILS LOUDLY if it never appears (instead of silently skipping, which
# is what left CloudFront with no /api origin → empty menu / AI "warming up").
# If this step ever fails, just re-run:  bash wire-cloudfront.sh
bash "$GITOPS/wire-cloudfront.sh"

echo ""
echo "======================================================================"
echo "DONE. (CloudFront takes a few minutes to deploy the new origin.)"
echo "All access links + credentials below — re-print anytime with: bash links.sh"
echo "======================================================================"
# Single source of truth for every URL + credential.
bash "$GITOPS/links.sh"
