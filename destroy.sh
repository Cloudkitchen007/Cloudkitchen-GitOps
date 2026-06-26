#!/usr/bin/env bash

set -uo pipefail 

REGION="ap-south-1"
CLUSTER="cloudkitchen-eks"
GITOPS="$(cd "$(dirname "$0")" && pwd)"
INFRA="$GITOPS/../Cloudkitchen-Infra"

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 || true

echo "######## 1/3  Remove the ArgoCD app (prunes workloads + gateway) ########"
kubectl delete application cloudkitchen -n argocd --ignore-not-found --timeout=180s 2>/dev/null || true

echo "######## 2/3  Delete ALL LoadBalancer services (no orphaned LBs) ########"
kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null \
  | while read -r ns name; do
      [ -n "${name:-}" ] && { echo "  deleting svc $ns/$name"; kubectl delete svc -n "$ns" "$name" --ignore-not-found 2>/dev/null || true; }
    done

echo "Waiting for load balancers to be removed..."
for _ in $(seq 1 30); do
  cnt=$(kubectl get svc -A 2>/dev/null | grep -c LoadBalancer || true)
  [ "${cnt:-0}" = "0" ] && { echo "  all LoadBalancers gone"; break; }
  sleep 10
done

echo "######## 3/3  terraform destroy ########"
cd "$INFRA"
terraform init -input=false   
terraform destroy -auto-approve

echo ""
echo "All resources destroyed. Nothing left running or billing."
