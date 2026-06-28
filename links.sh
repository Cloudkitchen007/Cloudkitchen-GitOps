#!/usr/bin/env bash

set -uo pipefail

GITOPS="$(cd "$(dirname "$0")" && pwd)"
INFRA="$GITOPS/../Cloudkitchen-Infra"

lb() { kubectl -n "$1" get svc "$2" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null; }

echo "================ CloudKitchen access ================"

APP="$(terraform -chdir="$INFRA" output -raw cloudfront_url 2>/dev/null)"
echo "APP (CloudFront):  https://${APP:-<run terraform output cloudfront_url>}"
echo

ARGO="$(lb argocd argocd-server)"
echo "ArgoCD:            http://${ARGO:-<not ready>}"
echo "  user: admin"
echo "  pass: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
echo

GRAF="$(lb monitoring kube-prometheus-stack-grafana)"
echo "Grafana:           http://${GRAF:-<not ready — run: helm upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack --namespace monitoring --version 65.1.1 -f monitoring/values.yaml>}"
echo "  user: admin   pass: cloudkitchen-admin"
echo

echo "Prometheus:        kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090  → http://localhost:9090"
echo
echo "── ArgoCD app status ────────────────────────────────"
kubectl get application -n argocd 2>/dev/null || echo "  (argocd not ready)"
echo
echo "── Pod health ───────────────────────────────────────"
for NS in prod dev; do
  echo "  namespace: $NS"
  kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '{printf "    %-45s %s/%s\n", $1, $2, $3}' || echo "    (namespace not ready)"
done
echo "===================================================="
