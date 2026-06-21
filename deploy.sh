#!/usr/bin/env bash
# =============================================================================
# CloudKitchen — ONE-COMMAND DEPLOY (3-repo, EKS-only)
#
#   ./deploy.sh
#
# Assumes the three repos are cloned SIDE BY SIDE:
#   <parent>/cloudkitchen-app
#   <parent>/cloudkitchen-infra
#   <parent>/cloudkitchen-gitops   ← run this script from here
#
# Flow:
#   1. terraform apply (infra: VPC, EKS, RDS, ECR, IRSA, SQS, Cognito,
#      Secrets Manager, Container Insights)
#   2. build + push all 5 service images to ECR (infra no longer builds them)
#   3. install the platform (kgateway, ESO, ArgoCD-public, Prometheus/Grafana)
#   4. hand the app to ArgoCD (GitOps) — ESO syncs secrets, ArgoCD syncs workloads
#
# Prereqs: terraform, aws, kubectl, docker (running), git. helm auto-installs.
# =============================================================================
set -euo pipefail

REGION="ap-south-1"
CLUSTER="cloudkitchen-eks"
ACCOUNT="256603361470"
ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
GITOPS="$(cd "$(dirname "$0")" && pwd)"
INFRA="$GITOPS/../cloudkitchen-infra"
APP="$GITOPS/../cloudkitchen-app"

echo "Preflight checks..."
for t in terraform aws kubectl docker; do command -v "$t" >/dev/null || { echo "ERROR: $t not installed."; exit 1; }; done
docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not running."; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "ERROR: AWS credentials not configured."; exit 1; }
[ -d "$INFRA" ] || { echo "ERROR: sibling repo not found: $INFRA (clone all 3 repos side by side)."; exit 1; }
[ -d "$APP" ]   || { echo "ERROR: sibling repo not found: $APP."; exit 1; }
[ -f "$INFRA/terraform.tfvars" ] || { echo "ERROR: $INFRA/terraform.tfvars missing (gitignored; holds hf_api_token, key_name)."; exit 1; }
grep -q "<YOUR-ORG>" "$GITOPS/argocd/application.yaml" && \
  echo "WARNING: argocd/application.yaml still has <YOUR-ORG>. Set repoURL to your cloudkitchen-gitops repo (and push it) so ArgoCD can sync."

# ensure helm
if ! command -v helm >/dev/null 2>&1 && [ ! -x "$HOME/bin/helm.exe" ]; then
  echo "Installing helm locally..."
  curl -fsSL https://get.helm.sh/helm-v3.16.3-windows-amd64.zip -o /tmp/helm.zip
  unzip -oq /tmp/helm.zip -d /tmp && mkdir -p "$HOME/bin" && cp /tmp/windows-amd64/helm.exe "$HOME/bin/helm.exe"
fi
export PATH="$HOME/bin:$PATH"

echo "######## 1/4  Terraform apply (infra) ########"
cd "$INFRA"
terraform init -input=false
terraform apply -auto-approve

echo "######## 2/4  Build + push images to ECR ########"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"
build() { echo "--- $1 ---"; docker build -t "$ECR/$2:latest" "$APP/$1"; docker push "$ECR/$2:latest"; }
build menu-service   cloudkitchen-menu-repo
build order-service  cloudkitchen-order-repo
build auth-service   cloudkitchen-auth-repo
build ai-recommender cloudkitchen-ai-repo
build frontend       cloudkitchen-app-repo

echo "######## 3/4  Platform (kgateway, ESO, ArgoCD, monitoring) ########"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
bash "$GITOPS/bootstrap/install.sh"

echo "######## 4/4  Deploy app via ArgoCD ########"
kubectl apply -f "$GITOPS/argocd/project.yaml"
kubectl apply -f "$GITOPS/argocd/application.yaml"

echo ""
echo "======================================================================"
echo "DONE. ArgoCD will sync the app from your GitOps repo in ~1-2 min."
echo "  App:     kubectl get application cloudkitchen -n argocd"
echo "  Pods:    kubectl get pods -n production"
echo "  EKS NLB: kubectl get gateway cloudkitchen-gateway -n production -o jsonpath='{.status.addresses[0].value}'"
echo "  ArgoCD:  http://\$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "  Grafana: http://\$(kubectl -n monitoring get svc kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "======================================================================"
