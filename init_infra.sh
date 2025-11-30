#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# --- 1. Configuration Setup ---

# Check if configuration file exists
if [ ! -f .gcpenv ]; then
    echo "Error: Configuration file '.gcpenv' not found."
    echo "Please copy 'sample_vars.sh' to '.gcpenv' and update values."
    exit 1
fi

# Load environment variables
source .gcpenv

# Ensure gcloud uses the correct project ID from config
gcloud config set project "$PROJECT_ID"

echo "--- Generating Configuration Files from Templates ---"
mkdir -p k8s

# --- CRITICAL FIX: Variable Substitution Logic ---
# 1. We need to prevent envsubst from replacing $COMMIT_SHA (it exists only during build time).
export COMMIT_SHA='$COMMIT_SHA'

# 2. We need to prevent envsubst from replacing $DB_PASS in cloudbuild.yaml.
# Cloud Build must fetch the password from Secret Manager at runtime using '$$DB_PASS'.
# However, we DO need the real password for K8s secrets and Cloud SQL creation.

# Save the real password
REAL_DB_PASS=$DB_PASS

# Set placeholder for Cloud Build generation
export DB_PASS='$$DB_PASS'

# Generate Cloud Build configuration (contains $$DB_PASS)
envsubst < templates/cloudbuild.yaml > cloudbuild.yaml

# Restore the real password for the rest of the script
export DB_PASS=$REAL_DB_PASS

# Generate Kubernetes manifests (contains real DB_PASS in base64 encoded secret via kubectl later)
envsubst < templates/deployment.yaml > k8s/deployment.yaml
envsubst < templates/service.yaml > k8s/service.yaml
envsubst < templates/ingress.yaml > k8s/ingress.yaml

echo "--- Configuration generated in k8s/ and cloudbuild.yaml ---"

echo "--- Setting up GCP Infrastructure ---"

# Enable required GCP APIs
gcloud services enable artifactregistry.googleapis.com \
    container.googleapis.com \
    cloudbuild.googleapis.com \
    sqladmin.googleapis.com \
    secretmanager.googleapis.com

# 1. Network & Static IP
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --global > /dev/null 2>&1; then
    echo "Creating Static IP: $STATIC_IP_NAME..."
    gcloud compute addresses create "$STATIC_IP_NAME" --global
else
    echo "Static IP $STATIC_IP_NAME already exists. Skipping."
fi

# 2. Artifact Registry
if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" > /dev/null 2>&1; then
    echo "Creating Artifact Registry: $REPO_NAME..."
    gcloud artifacts repositories create "$REPO_NAME" --repository-format=docker --location="$REGION"
else
    echo "Repository $REPO_NAME already exists. Skipping."
fi

# 3. Secret Manager (Database Password)
if ! gcloud secrets describe sql-password > /dev/null 2>&1; then
    echo "Creating Secret: sql-password..."
    printf "$DB_PASS" | gcloud secrets create sql-password --data-file=-
else
    echo "Secret sql-password already exists. Skipping."
fi

# 4. Cloud SQL (This takes 5-10 minutes)
if ! gcloud sql instances describe "$SQL_INSTANCE_NAME" > /dev/null 2>&1; then
    echo "Creating Cloud SQL Instance: $SQL_INSTANCE_NAME (this may take a while)..."
    gcloud sql instances create "$SQL_INSTANCE_NAME" \
        --database-version=POSTGRES_13 \
        --cpu=1 --memory=4GB \
        --region="$REGION" \
        --root-password="$DB_PASS" \
        --availability-type=ZONAL
    
    echo "Creating Database and User..."
    gcloud sql databases create "$DB_NAME" --instance="$SQL_INSTANCE_NAME"
    gcloud sql users create "$DB_USER" --instance="$SQL_INSTANCE_NAME" --password="$DB_PASS"
else
    echo "Cloud SQL Instance $SQL_INSTANCE_NAME already exists. Skipping."
fi

# 5. GKE Cluster
if ! gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" > /dev/null 2>&1; then
    echo "Creating GKE Cluster: $CLUSTER_NAME..."
    gcloud container clusters create "$CLUSTER_NAME" \
        --zone "$ZONE" \
        --num-nodes 1 \
        --scopes=cloud-platform
else
    echo "GKE Cluster $CLUSTER_NAME already exists. Skipping."
fi

# --- Kubernetes Configuration ---

echo "--- Configuring Kubernetes ---"
# Get credentials for kubectl
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE"

# Create/Update secret inside K8s
# (Using dry-run allows this command to run safely even if secret exists)
kubectl create secret generic db-credentials \
    --from-literal=database_url="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}" \
    --dry-run=client -o yaml | kubectl apply -f -

# --- IAM Permissions ---

echo "--- Configuring IAM Permissions ---"
# Get Project Number
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

# Define Service Accounts
# 1. Default Cloud Build SA
CB_SA="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
# 2. Default Compute SA (sometimes used by Cloud Build by default)
COMPUTE_SA="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# Helper function to grant roles
grant_role() {
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$1" --role="$2" > /dev/null
}

echo "Granting roles to Service Accounts..."

# Loop through both service accounts to ensure permissions are set correctly
for SA in $CB_SA $COMPUTE_SA; do
    echo "Configuring $SA..."
    # Allow reading secrets (to access DB password)
    grant_role $SA "roles/secretmanager.secretAccessor"
    # Allow Cloud SQL connection (for migrations)
    grant_role $SA "roles/cloudsql.client"
    # Allow GKE deployment (for kubectl apply)
    grant_role $SA "roles/container.developer"
done

echo "--- Infrastructure Setup Complete ---"