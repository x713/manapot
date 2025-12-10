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

# --- Script generation ---
./gen_infra.sh

# --- Infrastructure Setup ---
./init_infra.sh

