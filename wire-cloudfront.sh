#!/usr/bin/env bash
# =============================================================================
# Re-point CloudFront /api + /auth at the CURRENT EKS NLB, then invalidate.
#
#   bash wire-cloudfront.sh
#
# Run this ANY time the app shows an empty menu / "AI warming up" after a
# destroy-recreate. Cause: each recreate gives Kubernetes a NEW NLB DNS name,
# and CloudFront must be re-pointed at it. This script is idempotent and waits
# for the NLB to exist, so it can't silently skip the way deploy.sh step 5 can.
# =============================================================================
set -euo pipefail

REGION="ap-south-1"
INFRA="$(cd "$(dirname "$0")/../cloudkitchen-infra" && pwd)"

echo "Waiting for the kgateway NLB (ArgoCD must have synced the Gateway)..."
NLB=""
for _ in $(seq 1 60); do  # up to 10 min
  NLB="$(kubectl get gateway cloudkitchen-gateway -n production -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  [ -n "$NLB" ] && break
  sleep 10
done
[ -n "$NLB" ] || { echo "ERROR: NLB still not ready. Is the gitops repo pushed and ArgoCD synced? (kubectl get gateway -n production)"; exit 1; }
echo "NLB: $NLB"

cd "$INFRA"
terraform apply -auto-approve -var="eks_api_origin=$NLB"

DIST="$(terraform output -raw cloudfront_distribution_id)"
aws cloudfront create-invalidation --distribution-id "$DIST" --region "$REGION" --paths '/*' >/dev/null
echo ""
echo "Done. CloudFront /api + /auth now point at $NLB."
echo "Give CloudFront ~3-5 min to deploy, then hard-refresh:"
echo "  https://$(terraform output -raw cloudfront_url)"
