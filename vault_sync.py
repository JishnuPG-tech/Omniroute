#!/usr/bin/env python3
"""
OmniRoute Cloud Vault Synchronizer
===================================
Provides zero-loss persistence across arbitrary container restarts, rebuilds,
and ephemeral-disk resets by maintaining a bidirectional sync between
/data/omniroute and a private Hugging Face Dataset repository.
"""

import os
import sys
import shutil
import sqlite3
import logging
from datetime import datetime

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] [VaultSync] %(message)s")
logger = logging.getLogger("VaultSync")

VAULT_REPO = os.environ.get("OMNIROUTE_VAULT_REPO", "Jishnupg/omniroute-storage-vault")
DATA_DIR = os.environ.get("DATA_DIR", "/data/omniroute")
DB_PATH = os.path.join(DATA_DIR, "storage.sqlite")
HF_TOKEN = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_API_KEY")

def get_hf_api():
    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_API_KEY")
    if not token:
        logger.warning("HF_TOKEN is not set; cloud vault sync is disabled.")
        return None, "HF_TOKEN is not set in environment"
    try:
        from huggingface_hub import HfApi
        return HfApi(token=token), None
    except ImportError as exc:
        logger.error(f"huggingface_hub import error: {exc}")
        return None, f"huggingface_hub import error: {exc}"

def restore_from_vault() -> tuple[bool, str]:
    """Restores storage.sqlite from private HF Dataset if local database is absent or empty."""
    os.makedirs(DATA_DIR, exist_ok=True)
    
    # If a valid local database already exists with positive size, keep local state as authoritative
    if os.path.exists(DB_PATH) and os.path.getsize(DB_PATH) > 0:
        msg = f"Authoritative local database found at {DB_PATH} ({os.path.getsize(DB_PATH)} bytes)."
        logger.info(msg)
        return True, msg

    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_API_KEY")
    if not token:
        msg = "No HF_TOKEN available to restore from cloud vault."
        logger.info(msg)
        return False, msg

    try:
        from huggingface_hub import hf_hub_download
        logger.info(f"Attempting to restore database from cloud vault {VAULT_REPO}...")
        downloaded = hf_hub_download(
            repo_id=VAULT_REPO,
            filename="storage.sqlite",
            repo_type="dataset",
            token=token,
            force_download=True
        )
        if downloaded and os.path.exists(downloaded) and os.path.getsize(downloaded) > 0:
            shutil.copy2(downloaded, DB_PATH)
            # Remove any stale WAL / SHM files
            for ext in ("-wal", "-shm"):
                p = DB_PATH + ext
                if os.path.exists(p):
                    os.remove(p)
            msg = f"Successfully restored database from cloud vault ({os.path.getsize(DB_PATH)} bytes) to {DB_PATH}."
            logger.info(msg)
            return True, msg
    except Exception as e:
        msg = f"No existing cloud vault snapshot found or restore failed: {e}"
        logger.warning(msg)
        return False, msg

    return False, "Restore failed"

def backup_to_vault() -> tuple[bool, str]:
    """Creates a consistent SQLite snapshot and uploads it to the private HF Dataset."""
    if not os.path.exists(DB_PATH) or os.path.getsize(DB_PATH) == 0:
        msg = f"Database at {DB_PATH} does not exist or is empty; skipping backup."
        logger.debug(msg)
        return False, msg

    api, err = get_hf_api()
    if not api:
        return False, err

    snapshot_path = os.path.join(DATA_DIR, "storage.sqlite.snapshot")
    try:
        # Create a consistent online backup using SQLite Backup API
        src_conn = sqlite3.connect(DB_PATH, timeout=10.0)
        dst_conn = sqlite3.connect(snapshot_path)
        with dst_conn:
            src_conn.backup(dst_conn, pages=100)
        dst_conn.close()
        src_conn.close()

        # Validate snapshot integrity before upload
        check_conn = sqlite3.connect(snapshot_path)
        cur = check_conn.cursor()
        cur.execute("PRAGMA quick_check;")
        res = cur.fetchone()
        check_conn.close()

        if not res or res[0] != "ok":
            msg = f"Snapshot integrity check failed: {res}. Skipping upload."
            logger.error(msg)
            if os.path.exists(snapshot_path):
                os.remove(snapshot_path)
            return False, msg

        commit_msg = f"Automated OmniRoute storage checkpoint [{datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}]"
        api.upload_file(
            path_or_fileobj=snapshot_path,
            path_in_repo="storage.sqlite",
            repo_id=VAULT_REPO,
            repo_type="dataset",
            commit_message=commit_msg
        )
        msg = f"Database checkpoint ({os.path.getsize(snapshot_path)} bytes) synced to cloud vault {VAULT_REPO}."
        logger.info(msg)
        return True, msg
    except Exception as e:
        msg = f"Failed to sync database to cloud vault: {e}"
        logger.error(msg)
        return False, msg
    finally:
        if os.path.exists(snapshot_path):
            try:
                os.remove(snapshot_path)
            except Exception:
                pass

if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "backup"
    if action == "restore":
        restore_from_vault()
    elif action == "backup":
        backup_to_vault()
    else:
        print(f"Usage: {sys.argv[0]} [restore|backup]")
