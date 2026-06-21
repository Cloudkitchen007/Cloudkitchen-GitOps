# CloudKitchen — Deploy from anywhere, in one command

The whole platform (AWS infra + EKS + 4 microservices + SPA + monitoring) deploys
with a **single script**. It works from any laptop, anywhere in the world, as long
as the prerequisites below are met.

There is exactly **one entrypoint to deploy** (`deploy.sh`) and **one to tear down**
(`destroy.sh`). Everything else (`bootstrap/install.sh`, `wire-cloudfront.sh`,
`links.sh`) is called automatically by `deploy.sh` — you never run them by hand
(though `links.sh` is handy on its own to re-print URLs).

---

## 1. Prerequisites (one-time per laptop)

Install these CLIs and make sure they're on your PATH:

| Tool | Why | Check |
|------|-----|-------|
| `aws` (v2) | talks to AWS | `aws --version` |
| `terraform` | provisions infra | `terraform version` |
| `kubectl` | drives the cluster | `kubectl version --client` |
| `docker` (running) | builds images | `docker info` |
| `npm` (Node 18+) | builds the SPA | `npm -v` |
| `git` | clones the repos | `git --version` |

> `helm` is installed automatically by the script if missing.

Then configure credentials + secrets (environment variables — nothing committed):

```bash
aws configure                 # access key, secret, region ap-south-1
export HF_API_TOKEN=hf_xxx    # required — free at huggingface.co/settings/tokens
export SLACK_WEBHOOK_URL=...   # optional — enables Grafana/Alertmanager → Slack
```

The AWS account is hard-coded to **256603361470** / region **ap-south-1**. To deploy
into a different account, change `ACCOUNT`/`REGION` in `deploy.sh` and the matching
values in `cloudkitchen-infra`.

---

## 2. Deploy (the one command)

```bash
git clone https://github.com/Cloudkitchen007/cloudkitchen-gitops.git
cd cloudkitchen-gitops
./deploy.sh
```

That's it. `deploy.sh` will, in order:

1. **Clone the sibling repos** (`cloudkitchen-infra`, `cloudkitchen-app`) next to this
   one if they aren't already there, and generate `terraform.tfvars` from your env vars.
2. `terraform apply` — VPC, RDS, EKS, IRSA, Secrets Manager, CloudFront, S3, SQS…
3. Build + push the **4 backend images** to ECR.
4. Build the **React SPA** and sync it to the frontend S3 bucket.
5. Install the platform (**kgateway, External Secrets, ArgoCD, Prometheus/Grafana**)
   and apply the ArgoCD app (which deploys the microservices via GitOps).
6. **Wire CloudFront → the EKS NLB** (second `terraform apply`) and invalidate the cache.
7. Print every URL + credential (same as `bash links.sh`).

Total time: ~20–30 min on a clean account (EKS + RDS dominate).

> **Note:** ArgoCD syncs the microservices from the **pushed** `cloudkitchen-gitops`
> repo, so make sure your changes here are pushed before deploying. The infra/app
> repos are built locally and don't need to be pushed for `deploy.sh` to work.

---

## 3. Access the running system

Run any time after deploy:

```bash
bash links.sh
```

It prints (URLs/passwords regenerate on every recreate, so always fetch them live):

- **App** — the CloudFront HTTPS URL (SPA + API on one origin)
- **ArgoCD** — public URL, user `admin` (password fetched for you)
- **Grafana** — public URL, `admin` / `cloudkitchen-admin`
- **Prometheus** — `kubectl port-forward` one-liner

---

## 4. Tear down (the one command)

```bash
./destroy.sh
```

Deletes the ArgoCD app, removes all LoadBalancers first (so no orphaned ENIs block
VPC deletion), then `terraform destroy`. Nothing left billing.

---

## Why it's safe to run repeatedly

- Every step is **idempotent** (`terraform apply`, `helm upgrade -i`, `kubectl apply`).
- The CloudFront→NLB wiring (`wire-cloudfront.sh`) waits for the new NLB and fails
  loudly instead of skipping — this was the cause of the old "empty menu / AI warming
  up" after a recreate (the new NLB DNS wasn't re-pointed). Re-run it standalone any
  time with `bash wire-cloudfront.sh`.
