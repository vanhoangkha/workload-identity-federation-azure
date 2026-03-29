"""Sync files to Cloud Storage from AWS EC2 via WIF."""
import os
from google.cloud import storage

def sync_directory(project_id, bucket_name, local_dir, gcs_prefix):
    client = storage.Client(project=project_id)
    bucket = client.bucket(bucket_name)
    count = 0
    for root, _, files in os.walk(local_dir):
        for f in files:
            local_path = os.path.join(root, f)
            blob = bucket.blob(f"{gcs_prefix}/{os.path.relpath(local_path, local_dir)}")
            blob.upload_from_filename(local_path)
            count += 1
    print(f"Synced {count} files to gs://{bucket_name}/{gcs_prefix}/")

if __name__ == "__main__":
    import sys
    sync_directory(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
