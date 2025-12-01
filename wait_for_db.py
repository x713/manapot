import socket
import time
import sys

# Connect to the Proxy container by its Cloud Build Step ID
host = "sql-proxy-runner"
port = 5432
timeout = 60

print(f"Waiting for Cloud SQL Proxy at {host}:{port}...")
start_time = time.time()

while True:
    try:
        # Try to resolve and connect
        with socket.create_connection((host, port), timeout=1):
            print("Connection successful! Proxy is ready.")
            sys.exit(0)
    except (OSError, ConnectionRefusedError, socket.gaierror):
        if time.time() - start_time > timeout:
            print(f"Timeout: Could not connect to {host}:{port} within {timeout} seconds.")
            sys.exit(1)
        time.sleep(2)
