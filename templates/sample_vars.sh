export PROJECT_ID=$(gcloud config get-value project)

export REGION="set-region-name"
export ZONE="set-zone_name"
#export REGION="europe-central2"
#export ZONE="europe-central2-a"

# DOCKER REPO
export REPO_NAME="change-my-reponame"
export IMAGE_NAME="flask-image"
# GKE
export CLUSTER_NAME="change-my-clustername"
# SQL
export SQL_INSTANCE_NAME="devops-flask-db-unique"
export DB_NAME="your_app_db"
export DB_USER="your_unique_username"
export DB_PASS="YourVeryStrongUniquePassword123!"

# NETWORK
export STATIC_IP_NAME="flask-static-ip"
# APP
export SERVICE_ACCOUNT_NAME="gke-sa"
export APP_NAME="flask-app"
