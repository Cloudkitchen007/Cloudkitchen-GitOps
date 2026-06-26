#!/usr/bin/env bash

set -uo pipefail

lb() { kubectl -n "$1" get svc "$2" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null; }

echo "================ CloudKitchen access ================"

APP="$(terraform -chdir=../cloudkitchen-infra output -raw cloudfront_url 2>/dev/null)"
echo "APP (CloudFront):  https://${APP:-<run terraform output cloudfront_url>}"
echo

ARGO="$(lb argocd argocd-server)"
echo "ArgoCD:            http://${ARGO:-<not ready>}"
echo "  user: admin"
echo "  pass: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
echo

GRAF="$(lb monitoring kube-prometheus-stack-grafana)"
echo "Grafana:           http://${GRAF:-<not ready — is monitoring installed? helm list -A>}"
echo "  user: admin   pass: cloudkitchen-admin"
echo

echo "Prometheus:        kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090  → http://localhost:9090"
echo "===================================================="
