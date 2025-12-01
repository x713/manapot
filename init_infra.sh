#!/bin/bash
set -e

# --- 1. Load Config ---
if [ ! -f .gcpenv ]; then
    echo "Error: .gcpenv not found."
    exit 1
fi
set -a
source .gcpenv
set +a
gcloud config set project "$PROJECT_ID"

echo "--- 2. Fetching Instance Connection Name ---"
REAL_CONN_NAME=$(gcloud sql instances describe "$SQL_INSTANCE_NAME" --format="value(connectionName)" 2>/dev/null)

if [ -z "$REAL_CONN_NAME" ]; then
    echo "WARNING: Could not fetch connection name. Using fallback."
    REAL_CONN_NAME="$PROJECT_ID:$REGION:$SQL_INSTANCE_NAME"
fi
echo "Using: $REAL_CONN_NAME"

# --- 3. Generate Cloud Build Config ---
echo "--- Generating Cloud Build Config ---"
# We DO NOT use envsubst for DB_USER/DB_NAME anymore. They are now secrets.
envsubst < templates/cloudbuild.yaml > cloudbuild.yaml

# Substitutions
sed -i 's|__COMMIT_SHA__|$COMMIT_SHA|g' cloudbuild.yaml
sed -i "s|__INSTANCE_CONNECTION_NAME__|$REAL_CONN_NAME|g" cloudbuild.yaml

# Safety Check
if grep -q "$DB_PASS" cloudbuild.yaml; then
    echo "CRITICAL ERROR: Password found in config!"
    exit 1
fi
echo "Verification Passed."

# --- 4. Generate K8s Manifests ---
mkdir -p k8s
envsubst < templates/deployment.yaml > k8s/deployment.yaml
envsubst < templates/service.yaml > k8s/service.yaml
envsubst < templates/ingress.yaml > k8s/ingress.yaml

# --- 5. Create ALL Secrets ---
echo "--- Creating Secrets ---"
# 1. Password
if ! gcloud secrets describe sql-password > /dev/null 2>&1; then
    printf "$DB_PASS" | gcloud secrets create sql-password --data-file=-
fi
# 2. User
if ! gcloud secrets describe sql-user > /dev/null 2>&1; then
    printf "$DB_USER" | gcloud secrets create sql-user --data-file=-
fi
# 3. DB Name
if ! gcloud secrets describe sql-db > /dev/null 2>&1; then
    printf "$DB_NAME" | gcloud secrets create sql-db --data-file=-
fi

# --- 6. IAM Permissions (Grant Access to ALL secrets) ---
echo "--- Updating IAM ---"
P_NUM=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
SAs=("serviceAccount:${P_NUM}@cloudbuild.gserviceaccount.com" "serviceAccount:${P_NUM}-compute@developer.gserviceaccount.com")

for SA in "${SAs[@]}"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/cloudsql.client" > /dev/null
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/secretmanager.secretAccessor" > /dev/null
done

# --- 7. Infrastructure Check ---
echo "--- Ensuring Public IP ---"
gcloud sql instances patch "$SQL_INSTANCE_NAME" --assign-ip --network=default

echo "--- Setup Complete ---"