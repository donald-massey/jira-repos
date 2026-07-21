"""
s3_utils.py
===========
boto3 S3 client wrapper. Ported from LND-8093 for the LND-8482 metadata repair.

Credentials come from the standard boto3 chain (AWS_* env vars, loaded from
.env by the entrypoint). Short-lived — refresh before each run.
"""
from __future__ import annotations

import logging
from typing import Any

import boto3
from botocore.config import Config

logger = logging.getLogger(__name__)


class S3Client:
    """boto3 S3 client wrapper that holds the target bucket and retry config."""

    def __init__(self, bucket: str, region: str = "us-east-1", max_attempts: int = 10):
        self.bucket = bucket
        config = Config(retries={"max_attempts": max_attempts, "mode": "standard"})
        self._client = boto3.client("s3", region_name=region, config=config)
        logger.info("S3Client initialised: bucket=%s region=%s", bucket, region)

    def _strip_prefix(self, key: str) -> str:
        """Drop an accidental s3://{bucket}/ prefix so callers can pass either form."""
        return key.replace(f"s3://{self.bucket}/", "")

    def upload_file(self, local_path: str, key: str) -> None:
        self._client.upload_file(local_path, self.bucket, self._strip_prefix(key))

    def upload_bytes(self, data: bytes, key: str) -> None:
        """Upload an in-memory buffer to key in a single PUT (the read-once fast path)."""
        self._client.put_object(Bucket=self.bucket, Key=self._strip_prefix(key), Body=data)

    def head_object(self, key: str) -> dict[str, Any]:
        return self._client.head_object(Bucket=self.bucket, Key=self._strip_prefix(key))

    def delete_object(self, key: str) -> dict[str, Any]:
        return self._client.delete_object(Bucket=self.bucket, Key=self._strip_prefix(key))

    def delete_objects(self, keys: list[str]) -> list[str]:
        """Delete up to 1000 keys in one request; return list of keys that failed."""
        objects = [{"Key": self._strip_prefix(k)} for k in keys]
        resp = self._client.delete_objects(
            Bucket=self.bucket,
            Delete={"Objects": objects, "Quiet": True},
        )
        return [e["Key"] for e in resp.get("Errors", [])]

    def upload_and_verify(self, local_path: str, key: str) -> int:
        """Upload local_path to key, HEAD the result, and return its S3 ContentLength."""
        self.upload_file(local_path, key)
        head = self.head_object(key)
        return head["ContentLength"]
