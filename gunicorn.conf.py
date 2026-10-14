"""Gunicorn settings, driven by environment variables so the image is configured at deploy time."""

import os


bind = f"0.0.0.0:{os.environ.get('PORT', '8080')}"
workers = int(os.environ.get("WEB_CONCURRENCY", "2"))
timeout = int(os.environ.get("GUNICORN_TIMEOUT", "30"))
graceful_timeout = int(os.environ.get("GUNICORN_GRACEFUL_TIMEOUT", "20"))

# Worker heartbeat on tmpfs: avoids disk-backed /tmp stalls and works with a read-only root filesystem.
worker_tmp_dir = "/dev/shm"

accesslog = "-"
