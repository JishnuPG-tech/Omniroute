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
    if not HF_TOKEN:
        logger.warning("HF_TOKEN is not set; cloud vault sync is disabled.")
        return None
    try:
        from huggingface_hub import HfApi
        return HfApi(token=HF_TOKEN)
    except ImportError:
        logger.error("huggingface_hub package is not installed.")
        return None

def restore_from_vault() -> bool:
    """Restores storage.sqlite from private HF Dataset if local database is absent or empty."""
    os.makedirs(DATA_DIR, exist_ok=True)
    
    # If a valid local database already exists with positive size, keep local state as authoritative
    if os.path.exists(DB_PATH) and os.path.getsize(DB_PATH) > 0:
        logger.info(f"Authoritative local database found at {DB_PATH} ({os.path.getsize(DB_PATH)} bytes).")
        return True

    if not HF_TOKEN:
        logger.info("No HF_TOKEN available to restore from cloud vault.")
        return False

    try:
        from huggingface_hub import hf_hub_download
        logger.info(f"Attempting to restore database from cloud vault {VAULT_REPO}...")
        downloaded = hf_hub_download(
            repo_id=VAULT_REPO,
            filename="storage.sqlite",
            repo_type="dataset",
            token=HF_TOKEN,
            force_download=True
        )
        if downloaded and os.path.exists(downloaded) and os.path.getsize(downloaded) > 0:
            shutil.copy2(downloaded, DB_PATH)
            # Remove any stale WAL / SHM files
            for ext in ("-wal", "-shm"):
                p = DB_PATH + ext
                if os.path.exists(p):
                    os.remove(p)
            logger.info(f"Successfully restored database from cloud vault ({os.path.getsize(DB_PATH)} bytes) to {DB_PATH}.")
            return True
    except Exception as e:
        logger.warning(f"No existing cloud vault snapshot found or restore failed: {e}")

    return False

def backup_to_vault() -> bool:
    """Creates a consistent SQLite snapshot and uploads it to the private HF Dataset."""
    if not os.path.exists(DB_PATH) or os.path.getsize(DB_PATH) == 0:
        logger.debug(f"Database at {DB_PATH} does not exist or is empty; skipping backup.")
        return False

    api = get_hf_api()
    if not api:
        return False

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
            logger.error(f"Snapshot integrity check failed: {res}. Skipping upload.")
            if os.path.exists(snapshot_path):
                os.remove(snapshot_path)
            return False

        commit_msg = f"Automated OmniRoute storage checkpoint [{datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}]"
        api.upload_file(
            path_or_fileobj=snapshot_path,
            path_in_repo="storage.sqlite",
            repo_id=VAULT_REPO,
            repo_type="dataset",
            commit_message=commit_msg
        )
        logger.info(f"Database checkpoint ({os.path.getsize(snapshot_path)} bytes) synced to cloud vault {VAULT_REPO}.")
        return True
    except Exception as e:
        logger.error(f"Failed to sync database to cloud vault: {e}")
        return False
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
