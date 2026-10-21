#!/usr/bin/env bash
# =====================================================================
# Tear down everything created by gcp-setup.sh (stop all billing)
#   bash scripts/gcp-cleanup.sh
# =====================================================================
set -uo pipefail

PROJECT_ID="madhav-test-471011"
REGION="asia-south1"
ZONE="asia-south1-a"
CLUSTER_NAME="madhav-test-gke"
GAR_REPO="sample-app-repo"
NODE_SA_EMAIL="gke-node-sa@${PROJECT_ID}.iam.gserviceaccount.com"
CICD_SA_EMAIL="github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com"

read -r -p "This deletes the GKE cluster, Artifact Registry repo, SAs and WIF pool in ${PROJECT_ID}. Type 'yes' to continue: " OK
[[ "$OK" == "yes" ]] || { echo "Aborted"; exit 1; }

gcloud config set project "$PROJECT_ID"

# Biggest cost first
gcloud container clusters delete "$CLUSTER_NAME" --zone="$ZONE" --quiet
gcloud artifacts repositories delete "$GAR_REPO" --location="$REGION" --quiet

gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA_EMAIL}" --role="roles/container.developer" --condition=None --quiet
gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${NODE_SA_EMAIL}" --role="roles/container.defaultNodeServiceAccount" --condition=None --quiet

gcloud iam service-accounts delete "$CICD_SA_EMAIL" --quiet
gcloud iam service-accounts delete "$NODE_SA_EMAIL" --quiet

# WIF pools are soft-deleted for 30 days (the name can't be reused until then)
gcloud iam workload-identity-pools delete github-pool --location=global --quiet

echo "Cleanup done. Check for leftover load balancers / disks:"
echo "  gcloud compute forwarding-rules list ; gcloud compute disks list"
