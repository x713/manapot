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

# Ensure PROJECT_ID is valid
if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(gcloud config get-value project)
fi
gcloud config set project "$PROJECT_ID"

echo "--- Determining Instance Connection Name ---"
# Check if instance exists (suppress error if not found)
REAL_CONN_NAME=$(gcloud sql instances describe "$SQL_INSTANCE_NAME" --format="value(connectionName)" 2>/dev/null || true)

if [ -z "$REAL_CONN_NAME" ]; then
    echo "    > Instance not found (expected for fresh run)."
    echo "    > Using predicted connection name."
    REAL_CONN_NAME="$PROJECT_ID:$REGION:$SQL_INSTANCE_NAME"
else
    echo "    > Found existing instance: $REAL_CONN_NAME"
fi
echo "    > Using: $REAL_CONN_NAME"

# --- Generate Cloud Build Config ---
echo "--- Generating Cloud Build Config ---"
# Temporarily unset sensitive variables to prevent substitution leak
DB_PASS_SAVE=$DB_PASS
DB_USER_SAVE=$DB_USER
DB_NAME_SAVE=$DB_NAME

unset DB_PASS
unset DB_USER
unset DB_NAME

# Substitute environment variables into cloudbuild.yaml
envsubst < templates/cloudbuild.yaml > cloudbuild.yaml

# Restore sensitive variables
DB_PASS=$DB_PASS_SAVE
DB_USER=$DB_USER_SAVE
DB_NAME=$DB_NAME_SAVE

# Substitutions
# Replace the instance connection name placeholder
sed -i "s|__INSTANCE_CONNECTION_NAME__|$REAL_CONN_NAME|g" cloudbuild.yaml

# CRITICAL FIX: Replace the commit SHA placeholder (__COMMIT_SHA__) with the literal Cloud Build variable string.
# This ensures Cloud Build sees $_COMMIT_SHA at runtime, resolving the "invalid build step name" error.
sed -i 's|__COMMIT_SHA__|$_COMMIT_SHA|g' cloudbuild.yaml 

# Safety Check
if grep -q "$DB_PASS" cloudbuild.yaml; then
    echo "CRITICAL ERROR: Password found in config!"
    exit 1
fi
echo "    > Verification Passed."

# --- Generate K8s Manifests ---
echo "--- Generating K8s Manifests ---"
mkdir -p k8s
envsubst < templates/deployment.yaml > k8s/deployment.yaml
envsubst < templates/service.yaml > k8s/service.yaml
envsubst < templates/ingress.yaml > k8s/ingress.yaml

echo "Generation Complete."
