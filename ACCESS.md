# Accessing the CloudKitchen UIs

All control-plane UIs are exposed as **public AWS LoadBalancers (NLBs)** — open them
from any laptop, no `port-forward` needed. The LB DNS names change on every
destroy/recreate, so don't hardcode them — run the commands below to fetch the
current URL + credentials.

> Prereq once per machine / recreate:
> ```bash
> aws eks update-kubeconfig --name cloudkitchen-eks --region ap-south-1
> ```

---

## The app
```bash
terraform -chdir=../cloudkitchen-infra output -raw cloudfront_url
```
Open `https://<that>` — CloudFront serves the SPA (S3) and forwards `/api` + `/auth`
to the EKS NLB.

---

## ArgoCD (GitOps dashboard)
```bash
echo "http://$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "user: admin"
echo "pass: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
```
Use **http** (server runs insecure behind the LB).

---

## Grafana (dashboards + metrics)
```bash
echo "http://$(kubectl -n monitoring get svc kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
```
Login: **admin / cloudkitchen-admin** (set in `monitoring/values.yaml`).

Prometheus is wired in as a Grafana datasource — use Grafana's **Explore** tab to run
raw PromQL; you rarely need the Prometheus UI directly.

---

## Prometheus (raw UI, optional)
Not publicly exposed (ClusterIP). Reach it with a temporary port-forward:
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# → http://localhost:9090
```

---

## One-shot: print all links + creds
```bash
bash links.sh
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `namespaces "monitoring" not found` | The monitoring stack isn't installed. Re-run `bash bootstrap/install.sh` (or just its step 5). Verify with `helm list -A`. |
| Command prints an empty line | LB not provisioned yet — wait ~2 min and retry. |
| URL won't resolve in browser | NLB DNS propagation lag (~2-3 min after creation). |
| Grafana 503 / bad gateway | Grafana pod still starting: `kubectl -n monitoring get pods`. |

> Note: `bootstrap/install.sh` uses `set -e`, so if any earlier step errors the
> script aborts before installing monitoring (step 5). If Grafana is ever missing
> after a deploy, that's almost always why — check `helm list -A` and re-run.
