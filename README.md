# GitHub Actions CI/CD → GKE with Helm (dev / qa / prod)

Test repo: a sample Node.js app, Dockerised, deployed with **one Helm chart** to **three environments** on a single cheap GKE cluster, driven by **branches**.

| Branch | GitHub Environment | K8s Namespace | Values file | Replicas |
|--------|-------------------|---------------|-------------|----------|
| `dev`  | `dev`  | `dev`  | `values-dev.yaml`  | 1 |
| `qa`   | `qa`   | `qa`   | `values-qa.yaml`   | 1 |
| `prod` | `prod` | `prod` | `values-prod.yaml` | 2 (HPA 2–4, PDB) |

GCP project: `madhav-test-471011` · Region: `asia-south1` (Mumbai) · Cluster: `madhav-test-gke` (zonal, `asia-south1-a`)

## Repo layout

```
app/                     Node.js (Express) sample app + Dockerfile
  server.js              /  /healthz  /readyz
  test.js                smoke test (npm test)
  Dockerfile             multi-stage, non-root
helm/sample-app/         Helm chart
  values.yaml            common defaults
  values-{dev,qa,prod}.yaml
  templates/             deployment, service, configmap, hpa, pdb, serviceaccount
.github/workflows/cicd.yaml   pipeline
scripts/gcp-setup.sh     one-time GCP setup (AR, SAs, GKE, WIF)
scripts/gcp-cleanup.sh   delete everything
```

## Pipeline flow

```
push to dev/qa/prod
   └─ test        npm test + helm lint/template for all 3 envs
       └─ build-push   docker build → Artifact Registry
                       tags: <branch>-<sha7>, <branch>-latest
           └─ deploy   helm upgrade --install -n <branch> --atomic --wait
```

- **PRs** into `dev`/`qa`/`prod` run only the `test` job.
- **Auth is keyless** — Workload Identity Federation, no JSON key in GitHub.
- `build-push`/`deploy` are **skipped until** the `WIF_PROVIDER` repo variable exists, so the pipeline stays green before GCP is set up.
- `--atomic` auto-rolls back a failed release.

## Setup

### 1. GCP (one time)

Run in Cloud Shell (or anywhere with `gcloud` + `kubectl`):

```bash
git clone https://github.com/MadhavSake/Github-action-cicd-helm-3-env-gke.git
cd Github-action-cicd-helm-3-env-gke
bash scripts/gcp-setup.sh
```

It creates:

| Resource | Name |
|---|---|
| Artifact Registry (Docker) | `asia-south1-docker.pkg.dev/madhav-test-471011/sample-app-repo` (keeps last 10, deletes >30d) |
| Node SA | `gke-node-sa@…` → `roles/container.defaultNodeServiceAccount`, AR reader on the repo |
| CI/CD SA | `github-actions-sa@…` → AR writer on the repo, `roles/container.developer` |
| GKE cluster | zonal, 1× `e2-medium` **Spot**, autoscale 1–3, 30 GB pd-standard, Workload Identity on |
| WIF | pool `github-pool`, provider `github-provider`, restricted to this repo |
| Namespaces | `dev`, `qa`, `prod` |

### 2. GitHub repo variables

The script prints the exact values at the end. Add them under **Settings → Secrets and variables → Actions → Variables**:

| Variable | Example |
|---|---|
| `WIF_PROVIDER` | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `GCP_SA_EMAIL` | `github-actions-sa@madhav-test-471011.iam.gserviceaccount.com` |

### 3. Protect prod (recommended)

**Settings → Environments → prod → Required reviewers** → add yourself. Prod deploys will then wait for approval.

### 4. Deploy

```bash
git checkout dev
# make a change in app/ or helm/
git commit -am "test dev deploy" && git push      # → deploys to namespace dev
# promote: open PR dev → qa, then qa → prod
```

## Verify

```bash
gcloud container clusters get-credentials madhav-test-gke --zone asia-south1-a --project madhav-test-471011
kubectl get pods -A -l app.kubernetes.io/name=sample-app
kubectl -n dev port-forward svc/sample-app 8080:80
curl localhost:8080/
# {"message":"Hello from DEV","environment":"dev","version":"dev-abc1234",...}
```

Rollback: `helm -n prod history sample-app` → `helm -n prod rollback sample-app <REVISION>`

## Run locally

```bash
cd app && npm ci && npm test && npm start
docker build -t sample-app ./app && docker run -p 8080:8080 -e APP_ENV=local sample-app
```

## Cost notes

- One **zonal** cluster's management fee is covered by the GKE free tier credit (one per billing account) — if you already have another zonal/Autopilot cluster on the same billing account, the ~$0.10/hr fee applies.
- Spot `e2-medium` + 30 GB pd-standard is the main cost. Spot nodes can be preempted — fine for testing, not for real prod.
- Service type is `ClusterIP` (no load balancer cost). Set `service.type: LoadBalancer` in a values file if you need a public IP.
- Scale to zero when idle (turn autoscaling off first, otherwise pending system pods bring a node back):
  ```bash
  gcloud container clusters update madhav-test-gke --zone asia-south1-a --node-pool default-pool --no-enable-autoscaling
  gcloud container clusters resize madhav-test-gke --zone asia-south1-a --node-pool default-pool --num-nodes 0 --quiet
  # back on: resize --num-nodes 1, then update --enable-autoscaling --min-nodes 1 --max-nodes 3
  ```
- Tear down: `bash scripts/gcp-cleanup.sh`
