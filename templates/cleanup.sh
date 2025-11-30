# Set resource names
export OLD_CLUSTER="change-my-clustername"
export OLD_SQL="change-my-sql-instancename"
export OLD_REPO="change-my-reponame"

# 1. Delete cluster
gcloud container clusters delete $OLD_CLUSTER --zone europe-central2-a --quiet --async

# 2. Delete database (takes tike, run and leave it running)
gcloud sql instances delete $OLD_SQL --quiet --async

# 3. Delete repository (optional)
gcloud artifacts repositories delete $OLD_REPO --location=europe-central2 --quiet

# 4. Free static IP (no need to delete "flask-static-ip" if you want to reus it)
