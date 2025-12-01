#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# --- 1. Configuration Setup ---

if [ ! -f .gcpenv ]; then
    echo "Error: Configuration file '.gcpenv' not found."
    exit 1
fi

source .gcpenv
gcloud config set project "$PROJECT_ID"

echo "--- Generating Configuration Files ---"
mkdir -p k8s


# --- SECURE SUBSTITUTION LOGIC ---

# 1. Generate Cloud Build config
# NOTE: Логика COMMIT_SHA удалена. Используем envsubst для подстановки основных переменных.
envsubst < templates/cloudbuild.yaml > cloudbuild.yaml

# Restore REAL password for K8s manifests
# (DB_PASS остается в среде и используется для K8s и SQL)
# --- K8S SECRET VARIABLE GENERATION ---

# 1. Define the correct DATABASE_URL format for Kubernetes Pods.
# The Flask application must connect to 127.0.0.1:5432, 
# where the Cloud SQL Proxy sidecar is listening.
K8S_DB_URL="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}"

# 2. Base64-encode the URL for the Kubernetes secret.
# This variable will be used by envsubst to populate k8s/secret.yaml.
BASE64_K8S_DB_URL=$(echo -n "${K8S_DB_URL}" | base64)

# --- GENERATE K8s FILES ---

# Generate K8s files (They must contain the real password for kubectl to apply secrets)
envsubst < templates/deployment.yaml > k8s/deployment.yaml
envsubst < templates/service.yaml > k8s/service.yaml
envsubst < templates/ingress.yaml > k8s/ingress.yaml

echo "--- Configs Generated ---"

# --- Infrastructure Setup (Idempotent) ---
# Enable APIs
gcloud services enable artifactregistry.googleapis.com container.googleapis.com cloudbuild.googleapis.com sqladmin.googleapis.com secretmanager.googleapis.com

# CRITICAL FIX: Ensure Service Networking is enabled and VPC Peering is set up 
# for Cloud SQL Private IP access. This is required before creating the instance.
gcloud services enable servicenetworking.googleapis.com

# NEW IDEMPOTENCY CHECK: Check if the required VPC peering address range exists 
# before creating it. This replaces the unsupported --if-not-exists flag.
if ! gcloud compute addresses describe google-managed-services-default --global > /dev/null 2>&1; then
    gcloud compute addresses create google-managed-services-default \
        --global \
        --purpose=VPC_PEERING \
        --prefix-length=16 \
        --network=default \
        --verbosity=none
fi

# CRITICAL FIX 2: Create the VPC Peering connection itself.
# This connection allows the VPC network 'default' to talk to Google's service network.
if ! gcloud services vpc-peerings describe servicenetworking-googleapis-com --network=default > /dev/null 2>&1; then
    gcloud services vpc-peerings connect \
        --service=servicenetworking.googleapis.com \
        --ranges=google-managed-services-default \
        --network=default \
        --project=$PROJECT_ID
fi


# Create Resources if missing
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --global > /dev/null 2>&1; then
    gcloud compute addresses create "$STATIC_IP_NAME" --global
fi

if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" > /dev/null 2>&1; then
    gcloud artifacts repositories create "$REPO_NAME" --repository-format=docker --location="$REGION"
fi

if ! gcloud secrets describe sql-password > /dev/null 2>&1; then
    printf "$DB_PASS" | gcloud secrets create sql-password --data-file=-
fi

if ! gcloud sql instances describe "$SQL_INSTANCE_NAME" > /dev/null 2>&1; then
    echo "Creating Cloud SQL instance with PRIVATE IP..."
    
    # CRITICAL: Since Private IP creation is idempotent, we just run the create command
    # using the corrected private access flag.
    gcloud sql instances create "$SQL_INSTANCE_NAME" \
        --database-version=POSTGRES_13 \
        --cpu=1 --memory=4GB \
        --region="$REGION" \
        --root-password="$DB_PASS" \
        --availability-type=ZONAL \
        --network=default \
        --no-assign-ip \
        --enable-private-service-connect
        
    gcloud sql databases create "$DB_NAME" --instance="$SQL_INSTANCE_NAME"
    gcloud sql users create "$DB_USER" --instance="$SQL_INSTANCE_NAME" --password="$DB_PASS"
fi

if ! gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" > /dev/null 2>&1; then
    gcloud container clusters create "$CLUSTER_NAME" --zone "$ZONE" --num-nodes 1 --scopes=cloud-platform
fi

# K8s Secrets (Uses the real DB_PASS)
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE"
kubectl create secret generic db-credentials \
    --from-literal=database_url="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}" \
    --dry-run=client -o yaml | kubectl apply -f -

# IAM Permissions
P_NUM=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
# Add both default Cloud Build SA and Compute SA for security
SAs=("serviceAccount:${P_NUM}@cloudbuild.gserviceaccount.com" "serviceAccount:${P_NUM}-compute@developer.gserviceaccount.com")

for SA in "${SAs[@]}"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/secretmanager.secretAccessor" > /dev/null
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/cloudsql.client" > /dev/null
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/container.developer" > /dev/null
done

echo "--- Setup Complete ---"