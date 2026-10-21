#!/usr/bin/env bash
# =====================================================================
# One-time GCP setup for the GitHub Actions -> GKE (Helm) pipeline
#   - Enables APIs
#   - Creates Artifact Registry (Docker) with a cleanup policy
#   - Creates 2 service accounts (GKE nodes, GitHub CI/CD)
#   - Creates a CHEAP zonal GKE cluster (1x e2-medium Spot node)
#   - Sets up Workload Identity Federation (keyless auth from GitHub)
#   - Creates dev / qa / prod namespaces
#
# Run in Cloud Shell or any machine with gcloud + kubectl:
#   bash scripts/gcp-setup.sh
# Each step is idempotent-ish: "already exists" errors are safe to ignore.
# =====================================================================
set -euo pipefail

# ---------------- Variables ----------------
export PROJECT_ID="madhav-test-471011"
export REGION="asia-south1"                 # Mumbai
export ZONE="asia-south1-a"
export CLUSTER_NAME="madhav-test-gke"
export GAR_REPO="sample-app-repo"

export NODE_SA_NAME="gke-node-sa"
export CICD_SA_NAME="github-actions-sa"
export NODE_SA_EMAIL="${NODE_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
export CICD_SA_EMAIL="${CICD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

export WIF_POOL="github-pool"
export WIF_PROVIDER="github-provider"
export GITHUB_REPO="MadhavSake/Github-action-cicd-helm-3-env-gke"   # exact case matters

gcloud config set project "$PROJECT_ID"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

# ---------------- 1. Enable APIs ----------------
gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com

# ---------------- 2. Artifact Registry ----------------
gcloud artifacts repositories create "$GAR_REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="Sample app images (dev/qa/prod)"

# Cleanup policy: keep the 10 most recent images, delete anything older than 30 days
cat > /tmp/gar-cleanup-policy.json <<'EOF'
[
  {
    "name": "keep-10-most-recent",
    "action": { "type": "Keep" },
    "mostRecentVersions": { "keepCount": 10 }
  },
  {
    "name": "delete-older-than-30d",
    "action": { "type": "Delete" },
    "condition": { "tagState": "ANY", "olderThan": "30d" }
  }
]
EOF
gcloud artifacts repositories set-cleanup-policies "$GAR_REPO" \
  --location="$REGION" \
  --policy=/tmp/gar-cleanup-policy.json \
  --no-dry-run

# ---------------- 3. Service accounts ----------------
# 3a. Minimal-privilege SA for GKE nodes (instead of the default Compute SA with Editor)
gcloud iam service-accounts create "$NODE_SA_NAME" \
  --display-name="GKE node service account"

# Google's predefined least-privilege role for nodes (logging, monitoring, metadata)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${NODE_SA_EMAIL}" \
  --role="roles/container.defaultNodeServiceAccount" --condition=None --quiet

# Nodes pull images from Artifact Registry (scoped to this repo only)
gcloud artifacts repositories add-iam-policy-binding "$GAR_REPO" \
  --location="$REGION" \
  --member="serviceAccount:${NODE_SA_EMAIL}" \
  --role="roles/artifactregistry.reader"

# 3b. SA used by GitHub Actions (push images + deploy to GKE)
gcloud iam service-accounts create "$CICD_SA_NAME" \
  --display-name="GitHub Actions CI/CD"

gcloud artifacts repositories add-iam-policy-binding "$GAR_REPO" \
  --location="$REGION" \
  --member="serviceAccount:${CICD_SA_EMAIL}" \
  --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA_EMAIL}" \
  --role="roles/container.developer" --condition=None --quiet

# ---------------- 4. Cheap GKE cluster ----------------
# Cost levers used:
#   - ZONAL cluster  -> management fee covered by GKE free tier (1 zonal/Autopilot cluster per billing account)
#   - 1 x e2-medium SPOT node (autoscale 1..3)  -> ~60-90% cheaper than on-demand
#   - pd-standard 30 GB boot disk
#   - SYSTEM-only logging/monitoring, managed Prometheus off
gcloud container clusters create "$CLUSTER_NAME" \
  --zone="$ZONE" \
  --release-channel=regular \
  --machine-type=e2-medium \
  --spot \
  --num-nodes=1 \
  --enable-autoscaling --min-nodes=1 --max-nodes=3 \
  --disk-type=pd-standard --disk-size=30 \
  --service-account="$NODE_SA_EMAIL" \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --enable-ip-alias \
  --enable-shielded-nodes \
  --enable-autorepair --enable-autoupgrade \
  --logging=SYSTEM --monitoring=SYSTEM \
  --no-enable-managed-prometheus \
  --addons=HorizontalPodAutoscaling,HttpLoadBalancing

gcloud container clusters get-credentials "$CLUSTER_NAME" --zone="$ZONE"

# Namespaces for the 3 environments (Helm also creates them with --create-namespace)
for NS in dev qa prod; do
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$NS" environment="$NS" --overwrite
done

# ---------------- 5. Workload Identity Federation (GitHub OIDC -> GCP, no JSON keys) ----------------
gcloud iam workload-identity-pools create "$WIF_POOL" \
  --location=global \
  --display-name="GitHub Actions pool"

gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
  --location=global \
  --workload-identity-pool="$WIF_POOL" \
  --display-name="GitHub provider" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository=='${GITHUB_REPO}'"

# Only workflows from THIS repo can impersonate the CI/CD SA
gcloud iam service-accounts add-iam-policy-binding "$CICD_SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_REPO}"

# ---------------- 6. Values for GitHub repo variables ----------------
WIF_PROVIDER_PATH="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"

cat <<EOF

=====================================================================
 Setup complete. Add these as GitHub *repository variables*
 (Settings -> Secrets and variables -> Actions -> Variables):

   WIF_PROVIDER = ${WIF_PROVIDER_PATH}
   GCP_SA_EMAIL = ${CICD_SA_EMAIL}

 Or with the gh CLI:
   gh variable set WIF_PROVIDER --repo ${GITHUB_REPO} --body "${WIF_PROVIDER_PATH}"
   gh variable set GCP_SA_EMAIL --repo ${GITHUB_REPO} --body "${CICD_SA_EMAIL}"

 Then push a commit to dev, qa or prod to deploy.
=====================================================================
EOF
