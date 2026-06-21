# CloudKitchen — EKS GitOps (Phase 2)

This directory is the **Kubernetes deployment layer** for running the 4 backend
microservices on the EKS cluster created by `infra/eks.tf`. It is self-contained
so you can later move it into a **separate GitOps repo** without changes.

```
gitops/
├── README.md                     ← you are here (request flow + install order)
├── bootstrap/
│   └── install.sh                ← one-time platform install (CRDs, kgateway, LB controller, ArgoCD)
├── helm/
│   └── cloudkitchen/             ← umbrella Helm chart: 4 services + Gateway + HTTPRoutes
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
└── argocd/
    ├── project.yaml              ← ArgoCD AppProject
    └── application.yaml          ← ArgoCD Application (points at helm/cloudkitchen)
```

---

## 1. How a request actually flows (the part you were confused about)

You have several network hops. Here is the **complete path of one API call**, top to bottom:

```
 [ Browser ]
     │   https://d3i8o2ylyc4cc6.cloudfront.net/api/menu
     ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │ CloudFront (CDN)                                                      │
 │   • default behavior   → S3 bucket  (React static files)             │
 │   • /api/*  behavior    → Origin = EKS NLB  ◄── change this origin    │
 │   • /auth/* behavior    → Origin = EKS NLB      from the old EC2 ALB  │
 └─────────────────────────────────────────────────────────────────────┘
     │   (only /api/* and /auth/* leave CloudFront toward the backend)
     ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │ AWS Network Load Balancer (L4)                                        │
 │   Created automatically by Kubernetes when kgateway's Gateway asks    │
 │   for a `Service type: LoadBalancer`. The AWS Load Balancer           │
 │   Controller turns that into an internet-facing NLB.                  │
 │   Targets = the EKS worker nodes (the managed node group).            │
 └─────────────────────────────────────────────────────────────────────┘
     │   forwards :80 → the kgateway Envoy proxy pods running on the nodes
     ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │ kgateway  =  Envoy proxy pods (the "data plane")                      │
 │   This is your "kgateway → envoy" layer. It reads the Gateway API     │
 │   objects (Gateway + HTTPRoute) and does L7 path routing:             │
 │       /api/orders*        → order  Service                            │
 │       /api/recommend*     → ai     Service                            │
 │       /api/demand*        → ai     Service                            │
 │       /auth/*             → auth   Service                            │
 │       /api/*  (default)   → menu   Service                            │
 └─────────────────────────────────────────────────────────────────────┘
     │   forwards to the matching ClusterIP Service
     ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │ Kubernetes Service (ClusterIP)  →  load-balances across Pods          │
 └─────────────────────────────────────────────────────────────────────┘
     │
     ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │ Application Pods (menu / order / auth / ai)                           │
 │   → RDS PostgreSQL, SQS, Cognito, HuggingFace API                     │
 └─────────────────────────────────────────────────────────────────────┘
```

### Plain-English version
1. **CloudFront** is the front door. Static files come from S3; anything under
   `/api/*` or `/auth/*` is forwarded to **one** backend origin.
2. That backend origin is the **NLB** (one DNS name). You do **not** point
   CloudFront at individual services — you point it at the NLB, and everything
   behind the NLB is Kubernetes' job.
3. The **NLB** is a dumb L4 forwarder. It just gets traffic onto the cluster
   nodes. It does **not** know about `/api/orders` vs `/api/menu`.
4. **kgateway (Envoy)** is the smart L7 router *inside* the cluster. It looks at
   the URL path and picks the right Service. This is the **only** place path
   routing happens in EKS.
5. **Service → Pods** is standard Kubernetes load balancing.

> **Key mental model:** NLB = "get me into the cluster" (L4). kgateway/Envoy =
> "route me to the right service" (L7). They are two different jobs; you need both.

### The one wiring change on the AWS side
Today CloudFront's `/api/*` origin is the **EC2 ALB**. To cut over to EKS, change
that origin's domain to the **NLB DNS name** (printed after install — see step 5
below) and add a `/auth/*` behavior pointing at the same NLB. Nothing else in
CloudFront changes. You can flip back to the ALB instantly if needed.

---

## 2. Install order (one-time)

Prerequisites: `kubectl`, `helm`, and `aws` configured; cluster reachable via
`aws eks update-kubeconfig --name cloudkitchen-eks --region ap-south-1`.

```bash
cd gitops/bootstrap
./install.sh        # installs Gateway API CRDs, kgateway, AWS LB Controller, ArgoCD
```

Then create the runtime Secret (kept OUT of git — see step 4) and let ArgoCD
deploy the app:

```bash
kubectl apply -f ../argocd/project.yaml
kubectl apply -f ../argocd/application.yaml
```

---

## 3. Images must exist in ECR first

The Helm chart references images at
`<account>.dkr.ecr.<region>.amazonaws.com/cloudkitchen-<svc>-repo:latest`.
Build & push all four before (or as part of) the first deploy:

```bash
aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin 256603361470.dkr.ecr.ap-south-1.amazonaws.com

for svc in menu order auth ai; do
  case $svc in
    menu)  dir=../../services/menu-service ;;
    order) dir=../../services/order-service ;;
    auth)  dir=../../services/auth-service ;;
    ai)    dir=../../services/ai-recommender ;;
  esac
  img=256603361470.dkr.ecr.ap-south-1.amazonaws.com/cloudkitchen-$svc-repo:latest
  docker build -t "$img" "$dir"
  docker push "$img"
done
```

> The 3 Java services need a `Dockerfile` that builds the jar (they already have
> one). The AI image is already CPU-only (~2.5 GB) per `services/ai-recommender/Dockerfile`.

---

## 4. Secrets (never commit these)

The chart expects a Secret named `cloudkitchen-secrets`. Create it once from your
Secrets Manager values (or use External Secrets Operator later):

```bash
kubectl create secret generic cloudkitchen-secrets \
  --from-literal=SPRING_DATASOURCE_URL="jdbc:postgresql://<rds-endpoint>:5432/cloudkitchen" \
  --from-literal=SPRING_DATASOURCE_USERNAME="postgres" \
  --from-literal=SPRING_DATASOURCE_PASSWORD="<password>" \
  --from-literal=HUGGINGFACEHUB_API_TOKEN="<hf-token>"
```

Non-secret config (region, Cognito IDs, SQS URL, HF model) lives in
`values.yaml` → rendered into the `cloudkitchen-config` ConfigMap.

---

## 5. Get the NLB DNS name (for the CloudFront origin)

After kgateway provisions the Gateway:

```bash
kubectl get gateway cloudkitchen-gateway -o jsonpath='{.status.addresses[0].value}'
# or
kubectl get svc -l gateway.networking.k8s.io/gateway-name=cloudkitchen-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
```

Put that hostname into CloudFront as the `/api/*` (and `/auth/*`) origin.

---

## 6. Moving to a separate repo later

This whole `gitops/` folder is portable. When you split it out:
- Point the ArgoCD `Application.spec.source.repoURL` at the new repo.
- Keep `bootstrap/` for cluster platform setup (run once per cluster).
- Everything under `helm/` is what ArgoCD continuously reconciles.
```
