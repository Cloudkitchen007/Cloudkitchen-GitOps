#!/usr/bin/env bash
# =============================================================================
# CloudKitchen EKS platform bootstrap (run ONCE per cluster, or every recreate)
#
# Installs, in order:
#   1. Gateway API CRDs            (Gateway/HTTPRoute resource types)
#   2. kgateway                    (Envoy-based Gateway API implementation → NLB)
#   3. External Secrets Operator   (AWS Secrets Manager → K8s Secrets, via IRSA)
#   4. ArgoCD                      (GitOps controller) — exposed via a PUBLIC
#                                   LoadBalancer so the UI works from any laptop
#                                   (no localhost / port-forward needed)
#   5. kube-prometheus-stack       (Prometheus + Grafana; Grafana = public LB)
#
# Prereqs: kubectl, helm, aws — kubeconfig pointed at the cluster:
#   aws eks update-kubeconfig --name cloudkitchen-eks --region ap-south-1
# =============================================================================
set -euo pipefail

GATEWAY_API_VERSION="v1.2.0"
KGATEWAY_VERSION="v2.0.0"

echo "==> 1/4  Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> 2/4  kgateway (${KGATEWAY_VERSION})..."
helm upgrade -i kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
  --version "${KGATEWAY_VERSION}" --namespace kgateway-system --create-namespace
helm upgrade -i kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
  --version "${KGATEWAY_VERSION}" --namespace kgateway-system
kubectl -n kgateway-system rollout status deploy/kgateway --timeout=180s || true

echo "==> 3/4  External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true
helm upgrade -i external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace --set installCRDs=true
kubectl -n external-secrets rollout status deploy/external-secrets --timeout=180s || true

echo "==> 4/4  ArgoCD (public LoadBalancer)..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# Serve the UI over plain HTTP behind the LB (avoids self-signed cert warnings)
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
# Expose the server publicly so the UI is reachable from any machine via a link
kubectl -n argocd patch svc argocd-server -p '{"spec":{"type":"LoadBalancer"}}'
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s || true

echo "==> 5/5  Monitoring: Prometheus + Grafana (public LoadBalancer)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true
helm upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f "$(dirname "$0")/../monitoring/values.yaml"
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=300s || true

echo ""
echo "============================================================================"
echo "Platform ready. Secrets are handled by External Secrets Operator —"
echo "the ExternalSecret in the Helm chart syncs AWS Secrets Manager →"
echo "cloudkitchen-secrets automatically (no manual 'kubectl create secret')."
echo ""
echo "Next: apply the ArgoCD app:"
echo "  kubectl apply -f ../argocd/project.yaml -f ../argocd/application.yaml"
echo ""
echo "── Public UI links (LB DNS may take ~2 min to appear) ──────────────────────"
echo "ArgoCD:  http://\$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "  user: admin   pass: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
echo ""
echo "Grafana: http://\$(kubectl -n monitoring get svc kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "  user: admin   pass: cloudkitchen-admin  (set in monitoring/values.yaml)"
echo "============================================================================"
