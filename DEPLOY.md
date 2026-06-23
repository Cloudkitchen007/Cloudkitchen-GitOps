# CloudKitchen — Deploy & Destroy Runbook

Everything deploys with **one command** and tears down with one command.
This doc tells you exactly how long each step takes, what "stuck" looks like vs. normal waiting,
and the exact recovery command for every known failure.

---

## Prerequisites (one-time per machine)

```bash
aws --version          # v2 required
terraform version      # any recent v1.x
kubectl version --client
docker info            # Docker must be RUNNING
npm -v                 # Node 18+
git --version
```

> `helm` is auto-installed by the script if missing.

**Credentials — set these before every new terminal session:**

```bash
aws configure                        # access key, secret, region ap-south-1
export HF_API_TOKEN=hf_xxx           # free token at huggingface.co/settings/tokens
export SLACK_WEBHOOK_URL=https://... # optional — Grafana/Alertmanager → Slack alerts
```

The AWS account is **256603361470** / region **ap-south-1** (hard-coded in `deploy.sh`).

---

## Deploy — one command

```bash
cd Cloudkitchen-GitOps
./deploy.sh
```

`deploy.sh` automatically clones `Cloudkitchen-Infra` and `Cloudkitchen-Application`
next to this repo if they aren't already there. Run from the `Cloudkitchen-GitOps` folder.

**Total time: ~30–45 min on a clean account.**

---

## Step-by-step timing & what to expect

| # | What happens | Normal wait | Looks stuck if… |
|---|---|---|---|
| **1a** | Bootstrap (S3 + DynamoDB for TF state) | ~2 min | — |
| **1b** | `terraform apply` — VPC, EKS, RDS, SQS, ECR, CloudFront, IRSA… | **15–25 min** | Still running at 35 min |
| **2** | Build + push 4 backend Docker images to ECR | ~5–10 min | Longer than 20 min |
| **3** | Build React SPA + sync to S3 | ~3 min | — |
| **4** | kgateway, ESO, ArgoCD, Prometheus/Grafana install | **10–15 min** | See Step 4 section below |
| **5** | ArgoCD syncs microservices; wire CloudFront → NLB | **5–15 min** | See Step 5 section below |

---

## Step 4 — Monitoring appears to hang (most common issue)

### What's happening

`install.sh` installs kube-prometheus-stack (Prometheus + Grafana + Alertmanager +
node-exporter + kube-state-metrics). It pulls **6+ container images** on a fresh cluster.
The last line waits up to **10 minutes** for Grafana to be ready:

```bash
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=600s || true
```

This is **normal waiting**, not a hang. It will always continue after 10 min (the `|| true`
means it never blocks the script permanently).

### Diagnose while waiting (open a second terminal)

```bash
# See if pods are pulling images or crashing
kubectl get pods -n monitoring

# If a pod is in ImagePullBackOff or Pending for > 5 min:
kubectl describe pod -n monitoring <pod-name>

# Watch it live
kubectl get pods -n monitoring -w
```

### Recovery — if deploy.sh exited at step 4

Re-run the platform install standalone — it's fully idempotent:

```bash
bash bootstrap/install.sh
```

Then continue from step 5:

```bash
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/application.yaml
bash wire-cloudfront.sh
bash links.sh
```

---

## Step 5 — wire-cloudfront.sh appears to hang

### What's happening

`wire-cloudfront.sh` waits up to **10 minutes** for the kgateway NLB to appear:

```bash
kubectl get gateway cloudkitchen-gateway -n production \
  -o jsonpath='{.status.addresses[0].value}'
```

The NLB only appears **after** ArgoCD syncs the GitOps repo and the Gateway resource is created.
If ArgoCD hasn't synced yet, the loop runs until NLB appears or 10 min elapses.

### Diagnose while waiting

```bash
# Is ArgoCD synced?
kubectl get application cloudkitchen -n argocd

# Is the Gateway object there?
kubectl get gateway -n production

# Is the NLB address populated?
kubectl get gateway cloudkitchen-gateway -n production \
  -o jsonpath='{.status.addresses[0].value}'

# Are pods healthy?
kubectl get pods -n production
```

### Why ArgoCD may not have synced

- The `Cloudkitchen-GitOps` repo was not pushed before running `deploy.sh`
  → Push the repo, then force a sync: `kubectl -n argocd exec deploy/argocd-server -- argocd app sync cloudkitchen --insecure`
- ArgoCD pods are still starting (takes ~2–3 min after install)
  → `kubectl get pods -n argocd` — wait for all Running

### Re-run wire-cloudfront.sh standalone

Once the Gateway has an NLB address, this is safe to re-run any number of times:

```bash
bash wire-cloudfront.sh
```

If you see `ERROR: NLB still not ready`:

```bash
# Force ArgoCD sync
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
argocd login localhost:8080 --username admin --password "$ARGOCD_PASS" --insecure
argocd app sync cloudkitchen --insecure
# Wait ~3 min, then:
bash wire-cloudfront.sh
```

---

## Verify the deploy worked

Run after deploy.sh completes (or any time):

```bash
bash links.sh
```

**Quick health checks:**

```bash
# All 4 services Running (2 replicas each for menu/order/auth, 1 for ai)
kubectl get pods -n production

# ArgoCD shows Synced + Healthy
kubectl get application cloudkitchen -n argocd

# Secrets loaded from AWS Secrets Manager
kubectl get externalsecret -n production

# NLB has an address
kubectl get gateway cloudkitchen-gateway -n production

# CloudFront URL responds
curl -sI https://$(cd ../Cloudkitchen-Infra && terraform output -raw cloudfront_url) | head -2
```

---

## SNS email alerts — confirm after every redeploy

After each `terraform apply` a new SNS topic is created and a subscription confirmation
email is sent to `pruthvigbhaveri@gmail.com`.

**You must click "Confirm subscription" in that email** or DR-agent alerts will never arrive.

Search your inbox for: `AWS Notification - Subscription Confirmation`

If the email expired (> 3 days old), re-send it:

```bash
aws sns subscribe \
  --topic-arn $(cd ../Cloudkitchen-Infra && terraform output -raw sns_alerts_topic_arn 2>/dev/null || \
    aws sns list-topics --region ap-south-1 --query 'Topics[0].TopicArn' --output text) \
  --protocol email \
  --notification-endpoint pruthvigbhaveri@gmail.com \
  --region ap-south-1
```

---

## Destroy — one command

```bash
./destroy.sh
```

Order of operations (important — skipping steps orphans AWS resources that block billing):

1. Deletes the ArgoCD app → removes all K8s workloads + the Gateway
2. Deletes all `LoadBalancer` type Services → AWS deregisters and deletes the NLB(s)
3. Waits for NLBs to disappear (if you skip this, VPC deletion hangs on orphaned ENIs)
4. `terraform init` + `terraform destroy` — removes EKS, RDS, SQS, ECR, CloudFront, VPC

**What survives destroy** (intentional — needed for the next deploy):

| Resource | Why it survives |
|---|---|
| S3 state bucket `cloudkitchen-tfstate-256603361470` | Managed by `bootstrap/`, not main infra |
| DynamoDB lock table `cloudkitchen-tfstate-lock` | Same |
| ECR images | ECR repos are force-deleted — images are gone too |

**After destroy, `deploy.sh` will rebuild everything from scratch in ~30–45 min.**

---

## Recovery command cheat sheet

| Symptom | Command |
|---|---|
| Monitoring step slow / appeared to exit early | `bash bootstrap/install.sh` |
| wire-cloudfront.sh can't find NLB | `kubectl get gateway -n production` → wait or force ArgoCD sync |
| wire-cloudfront.sh ran successfully but menu is still empty | `bash wire-cloudfront.sh` (idempotent, safe to re-run) |
| Services in ImagePullBackOff | `kubectl describe pod -n production <name>` — check imageTag in ECR |
| ArgoCD shows OutOfSync | Push latest GitOps commit → ArgoCD auto-syncs within 3 min |
| No SNS email from DR-agent | Check subscription: `aws sns list-subscriptions-by-topic --topic-arn <arn> --region ap-south-1` |
| Just want the URLs again | `bash links.sh` |
| CloudFront serving stale frontend | `bash wire-cloudfront.sh` (also invalidates cache) |

---

## File map

```
Cloudkitchen-GitOps/
├── deploy.sh               ← ONLY entrypoint for full deploy
├── destroy.sh              ← ONLY entrypoint for full teardown
├── wire-cloudfront.sh      ← re-run standalone if CloudFront wiring failed
├── links.sh                ← re-print all URLs + credentials any time
├── bootstrap/
│   └── install.sh          ← re-run standalone if platform install failed (step 4)
├── helm/cloudkitchen/      ← ArgoCD deploys this Helm chart
│   ├── values.yaml         ← imageTags updated by CI (per-service) or deploy.sh (all)
│   └── templates/
├── argocd/                 ← ArgoCD project + application manifests
└── monitoring/values.yaml  ← Grafana/Prometheus config (Slack webhook, dashboards)
```
