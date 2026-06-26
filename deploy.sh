#!/usr/bin/env bash

set -euo pipefail

REGION="ap-south-1"
CLUSTER="cloudkitchen-eks"
ACCOUNT="256603361470"
ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
GITOPS="$(cd "$(dirname "$0")" && pwd)"
INFRA="$GITOPS/../Cloudkitchen-Infra"
APP="$GITOPS/../Cloudkitchen-Application"


GIT_ORG="${GIT_ORG:-Cloudkitchen007}"

echo "Preflight checks..."
for t in terraform aws kubectl docker npm git; do command -v "$t" >/dev/null || { echo "ERROR: $t not installed."; exit 1; }; done
docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not running."; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "ERROR: AWS credentials not configured (run 'aws configure')."; exit 1; }


clone_if_missing() {
  [ -d "$2" ] || { echo "Cloning $1 → $2"; git clone "https://github.com/$GIT_ORG/$1.git" "$2"; }
}
clone_if_missing Cloudkitchen-Infra       "$INFRA"
clone_if_missing Cloudkitchen-Application "$APP"


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


if ! command -v helm >/dev/null 2>&1 && [ ! -x "$HOME/bin/helm.exe" ]; then
  echo "Installing helm locally..."
  curl -fsSL https://get.helm.sh/helm-v3.16.3-windows-amd64.zip -o /tmp/helm.zip
  unzip -oq /tmp/helm.zip -d /tmp && mkdir -p "$HOME/bin" && cp /tmp/windows-amd64/helm.exe "$HOME/bin/helm.exe"
fi
export PATH="$HOME/bin:$PATH"

echo "######## 1/5  Terraform apply (infra) ########"
echo "--- bootstrap remote state (S3 + DynamoDB) ---"
(
  cd "$INFRA/bootstrap"
  terraform init -input=false


  _import() {
    terraform state show "$1" >/dev/null 2>&1 && return 0  
    terraform import "$1" "$2" 2>/dev/null && return 0     
    return 0                                                 
  }
  _import aws_s3_bucket.tfstate                               "cloudkitchen-tfstate-$ACCOUNT"
  _import aws_s3_bucket_versioning.tfstate                    "cloudkitchen-tfstate-$ACCOUNT"
  _import aws_s3_bucket_server_side_encryption_configuration.tfstate "cloudkitchen-tfstate-$ACCOUNT"
  _import aws_s3_bucket_public_access_block.tfstate           "cloudkitchen-tfstate-$ACCOUNT"
  _import aws_s3_bucket_lifecycle_configuration.tfstate       "cloudkitchen-tfstate-$ACCOUNT"
  _import aws_dynamodb_table.tfstate_lock                     "cloudkitchen-tfstate-lock"

  terraform apply -auto-approve
)
cd "$INFRA"

LOCK_KEY="cloudkitchen-tfstate-$ACCOUNT/cloudkitchen/terraform.tfstate-md5"
aws dynamodb delete-item \
  --table-name cloudkitchen-tfstate-lock \
  --key "{\"LockID\":{\"S\":\"$LOCK_KEY\"}}" \
  --region "$REGION" 2>/dev/null || true
terraform init -input=false
terraform apply -auto-approve

echo "######## 2/5  Build + push BACKEND images to ECR ########"

APP_SHA="$(git -C "$APP" rev-parse HEAD)"
echo "App commit: $APP_SHA"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"
build() {
  echo "--- $1 ---"
  docker build -t "$ECR/$2:$APP_SHA" -t "$ECR/$2:latest" "$APP/$1"
  docker push "$ECR/$2:$APP_SHA"
  docker push "$ECR/$2:latest"
}
build menu-service   cloudkitchen-menu-repo
build order-service  cloudkitchen-order-repo
build auth-service   cloudkitchen-auth-repo
build ai-recommender cloudkitchen-ai-repo


VALUES="$GITOPS/helm/cloudkitchen/values.yaml"
for SVC in menu order auth ai; do
  sed -i "s|^  $SVC: *\"[^\"]*\"|  $SVC: \"$APP_SHA\"|" "$VALUES"
done
cd "$GITOPS"
git add helm/cloudkitchen/values.yaml
git diff --cached --quiet || git commit -m "deploy: update imageTags to $APP_SHA"
git push origin main

echo "######## 3/5  Build React SPA + sync to S3 ########"
FRONTEND_BUCKET="$(terraform -chdir="$INFRA" output -raw frontend_bucket_name)"

API_GW="$(terraform -chdir="$INFRA" output -raw api_gateway_url 2>/dev/null || echo "")"
( cd "$APP/frontend" && npm install && REACT_APP_API_GATEWAY_URL="$API_GW" npm run build )
aws s3 sync "$APP/frontend/build/" "s3://$FRONTEND_BUCKET" --delete

echo "######## 4/5  Platform + deploy app via ArgoCD ########"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
bash "$GITOPS/bootstrap/install.sh"
kubectl apply -f "$GITOPS/argocd/project.yaml"
kubectl apply -f "$GITOPS/argocd/application.yaml"

echo "######## 5/5  Wire CloudFront → EKS NLB ########"

bash "$GITOPS/wire-cloudfront.sh"

echo ""
echo "======================================================================"
echo "DONE. (CloudFront takes a few minutes to deploy the new origin.)"
echo "All access links + credentials below — re-print anytime with: bash links.sh"
echo "======================================================================"

bash "$GITOPS/links.sh"
