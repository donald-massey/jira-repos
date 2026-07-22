import os
import csv
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

PROD_SOURCE = r'\\aus2-cs-fss01.na.drillinginfo.com\leasing_images_uncompressed'
DEV_SOURCE = r'\\aus2-cs-fss01.na.drillinginfo.com\leasing_images_uncompressed\_DEV'
PROD_BUCKET = 'leasing-images-uncompressed-prod'
DEV_BUCKET = 'leasing-images-uncompressed-dev'
REGION = 'us-east-1'
MAX_WORKERS = 32

_thread_local = threading.local()


def _get_client():
    if not hasattr(_thread_local, 'client'):
        _thread_local.client = boto3.client(
            's3',
            region_name=REGION,
            config=Config(retries={'max_attempts': 10, 'mode': 'standard'}),
        )
    return _thread_local.client


def list_existing_keys(bucket):
    client = _get_client()
    existing = set()
    paginator = client.get_paginator('list_objects_v2')
    for page in paginator.paginate(Bucket=bucket):
        for obj in page.get('Contents', []):
            existing.add(obj['Key'])
    return existing


def collect_files(source_root, exclude_dirs=None):
    exclude = set(exclude_dirs or [])
    for dirpath, dirnames, filenames in os.walk(source_root):
        # Only prune at the top level so _DEV isn't excluded from nested paths
        if os.path.normpath(dirpath) == os.path.normpath(source_root):
            dirnames[:] = [d for d in dirnames if d not in exclude]
        for filename in filenames:
            yield os.path.join(dirpath, filename)


def _upload_one(local_path, source_root, bucket, existing_keys):
    rel = os.path.relpath(local_path, source_root).replace('\\', '/')
    if rel in existing_keys:
        return local_path, 'skipped', None
    try:
        _get_client().upload_file(local_path, bucket, rel)
        return local_path, 'uploaded', None
    except ClientError as e:
        return local_path, 'error', str(e)
    except Exception as e:
        return local_path, 'error', str(e)


def copy_share_to_s3(source_root, bucket, exclude_dirs=None, workers=MAX_WORKERS):
    print(f"Listing existing keys in s3://{bucket} ...")
    existing_keys = list_existing_keys(bucket)
    print(f"  {len(existing_keys):,} keys already present")

    print(f"Collecting files from {source_root} ...")
    files = list(collect_files(source_root, exclude_dirs))
    total = len(files)
    print(f"  {total:,} files found — starting upload with {workers} threads\n")

    error_log = f"errors_{bucket}.csv"
    uploaded = skipped = errors = 0

    with open(error_log, 'w', newline='', encoding='utf-8') as ef:
        writer = csv.writer(ef)
        writer.writerow(['file', 'error'])

        with ThreadPoolExecutor(max_workers=workers) as executor:
            futures = {
                executor.submit(_upload_one, fp, source_root, bucket, existing_keys): fp
                for fp in files
            }

            for i, future in enumerate(as_completed(futures), start=1):
                path, status, err = future.result()
                if status == 'uploaded':
                    uploaded += 1
                elif status == 'skipped':
                    skipped += 1
                else:
                    errors += 1
                    writer.writerow([path, err])

                if i % 1000 == 0 or i == total:
                    print(
                        f"  {i:,}/{total:,} | "
                        f"uploaded={uploaded:,}  skipped={skipped:,}  errors={errors:,}"
                    )

    print(f"\nDone: uploaded={uploaded:,}  skipped={skipped:,}  errors={errors:,}")
    if errors:
        print(f"  Error details written to {error_log}")


if __name__ == '__main__':
    print("=== PROD COPY ===")
    copy_share_to_s3(PROD_SOURCE, PROD_BUCKET, exclude_dirs=['_DEV'])

    print()
    print("=== DEV COPY ===")
    copy_share_to_s3(DEV_SOURCE, DEV_BUCKET)
