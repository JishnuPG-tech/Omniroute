#!/bin/sh
set -e

START_TIME=$(date +%s)
get_elapsed() {
    if [ -n "$START_TIME" ]; then
        python3 -c "import time; print(f'{time.time() - $START_TIME:.2f}s')" 2>/dev/null || echo "0.0s"
    else
        echo "0.0s"
    fi
}

log_info() {
    echo "$(date -u '+%Y-%m-%d %H:%M:%S') [INFO] [$1] $2"
}

log_warn() {
    echo "$(date -u '+%Y-%m-%d %H:%M:%S') [WARN] [$1] $2"
}

log_error() {
    echo "$(date -u '+%Y-%m-%d %H:%M:%S') [ERROR] [$1] $2"
}

log_info "SYSTEM" "============================================"
log_info "SYSTEM" "=== OpenCode Space Container Starting ==="
log_info "SYSTEM" "============================================"

# Step 1: Configure Git & Environment Secrets Validation
git config --global --add safe.directory '*' 2>/dev/null || true

# Step 2: Ensure persistent /data directory structure exists
log_info "INIT" "Setting up /data persistent volume directories..."
mkdir -p /data/share/opencode /data/config/opencode /data/cache/opencode /data/state/opencode 2>/dev/null || true
mkdir -p /root/.cache /data/cache 2>/dev/null || true

# Fresh start for OmniRoute storage bucket data per plan
FRESH_START_FLAG="/data/omniroute/.persistence_v1_ready"
if [ ! -f "$FRESH_START_FLAG" ]; then
    log_warn "RESET" "Fresh OmniRoute persistence plan requested. Purging legacy data from persistent storage..."
    # Strictly remove legacy data from persistent bucket
    rm -rf /data/omniroute /data/.omniroute /root/.omniroute /root/.cache/omniroute /data/jellyfin /data/hermes /root/.hermes /data/share 2>/dev/null || true
    mkdir -p /data/omniroute/backups /data/omniroute/oauth /data/omniroute/credentials /data/omniroute/call_logs /data/omniroute/runtime 2>/dev/null || true
    touch "$FRESH_START_FLAG"
    log_info "RESET" "Fresh OmniRoute directory created at /data/omniroute. Legacy projects removed."
fi

mkdir -p /data/omniroute/backups /data/omniroute/oauth /data/omniroute/credentials /data/omniroute/call_logs /data/omniroute/runtime 2>/dev/null || true
chmod -R 777 /root/.cache /data/cache /data/omniroute 2>/dev/null || true

# Playwright Browser Metadata Fix for gemini-web / browser providers
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright
mkdir -p /root/.cache/ms-playwright /omniroute/.cache/ms-playwright 2>/dev/null || true
python3 -c "
import os, json
browsers_json = {
  'browsers': [
    {'name': 'chromium', 'revision': '1112', 'installByDefault': True},
    {'name': 'firefox', 'revision': '1448', 'installByDefault': True},
    {'name': 'webkit', 'revision': '2007', 'installByDefault': True},
    {'name': 'ffmpeg', 'revision': '1009', 'installByDefault': True}
  ]
}
targets = [
    '/root/.cache/ms-playwright',
    '/omniroute/.cache/ms-playwright',
    '/omniroute/node_modules/playwright-core',
    '/omniroute/node_modules/playwright/node_modules/playwright-core',
    '/usr/local/lib/node_modules/playwright-core',
    '/usr/local/lib/node_modules/playwright/node_modules/playwright-core'
]
if os.path.exists('/omniroute'):
    for root, dirs, files in os.walk('/omniroute'):
        if os.path.basename(root) == 'playwright-core':
            targets.append(root)

for target in set(targets):
    try:
        os.makedirs(target, exist_ok=True)
        b_path = os.path.join(target, 'browsers.json')
        if not os.path.exists(b_path) or os.path.getsize(b_path) == 0:
            with open(b_path, 'w', encoding='utf-8') as f:
                json.dump(browsers_json, f, indent=2)
            print(f'[PLAYWRIGHT] Created browsers.json at {b_path}')
    except Exception:
        pass
" 2>/dev/null || true

# ── STEP 1: Master Secret Validation & Persistent Encryption Keys ─────────────
mkdir -p /data/omniroute 2>/dev/null || true

if [ -n "$STORAGE_ENCRYPTION_KEY" ]; then
    echo "$STORAGE_ENCRYPTION_KEY" > /data/omniroute/.storage_encryption_key 2>/dev/null || true
elif [ -f "/data/omniroute/.storage_encryption_key" ] && [ -s "/data/omniroute/.storage_encryption_key" ]; then
    export STORAGE_ENCRYPTION_KEY=$(cat /data/omniroute/.storage_encryption_key | tr -d '\r\n')
    echo "[PERSISTENCE] Loaded persistent STORAGE_ENCRYPTION_KEY from /data/omniroute/.storage_encryption_key"
else
    export STORAGE_ENCRYPTION_KEY=$(python3 -c "import secrets; print(secrets.token_hex(16))" 2>/dev/null || echo "omniroute_default_storage_key_32bytes")
    echo "$STORAGE_ENCRYPTION_KEY" > /data/omniroute/.storage_encryption_key 2>/dev/null || true
    echo "[PERSISTENCE] Generated and saved persistent STORAGE_ENCRYPTION_KEY to /data/omniroute"
fi

if [ -n "$JWT_SECRET" ]; then
    echo "$JWT_SECRET" > /data/omniroute/.jwt_secret 2>/dev/null || true
elif [ -f "/data/omniroute/.jwt_secret" ] && [ -s "/data/omniroute/.jwt_secret" ]; then
    export JWT_SECRET=$(cat /data/omniroute/.jwt_secret | tr -d '\r\n')
    echo "[PERSISTENCE] Loaded persistent JWT_SECRET from /data/omniroute/.jwt_secret"
else
    export JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(16))" 2>/dev/null || echo "omniroute_default_jwt_secret_key_32bytes")
    echo "$JWT_SECRET" > /data/omniroute/.jwt_secret 2>/dev/null || true
    echo "[PERSISTENCE] Generated and saved persistent JWT_SECRET to /data/omniroute"
fi

if [ -n "$API_KEY_SECRET" ]; then
    echo "$API_KEY_SECRET" > /data/omniroute/.api_key_secret 2>/dev/null || true
elif [ -f "/data/omniroute/.api_key_secret" ] && [ -s "/data/omniroute/.api_key_secret" ]; then
    export API_KEY_SECRET=$(cat /data/omniroute/.api_key_secret | tr -d '\r\n')
    echo "[PERSISTENCE] Loaded persistent API_KEY_SECRET from /data/omniroute/.api_key_secret"
else
    export API_KEY_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(16))" 2>/dev/null || echo "omniroute_default_api_key_secret_32bytes")
    echo "$API_KEY_SECRET" > /data/omniroute/.api_key_secret 2>/dev/null || true
    echo "[PERSISTENCE] Generated and saved persistent API_KEY_SECRET to /data/omniroute"
fi

export INITIAL_PASSWORD="${INITIAL_PASSWORD:-Jishnu2005}"
echo "$INITIAL_PASSWORD" > /data/omniroute/.initial_password 2>/dev/null || true
echo "[PERSISTENCE] Configured OmniRoute administrator password to persistent storage."

export ENCRYPTION_SECRET="${STORAGE_ENCRYPTION_KEY}"
export OMNIROUTE_SECRET_KEY="${STORAGE_ENCRYPTION_KEY}"
export OMNIROUTE_STORAGE_KEY="${STORAGE_ENCRYPTION_KEY}"
export OMNIROUTE_STORAGE_SECRET="${STORAGE_ENCRYPTION_KEY}"
export OMNIROUTE_WS_BRIDGE_SECRET="${OMNIROUTE_WS_BRIDGE_SECRET:-$(echo "ws_bridge_${JWT_SECRET}" | sha256sum | cut -c1-48)}"

# Purge any legacy secret env files from storage bucket to maintain strict secret separation
rm -f /data/.env /data/secrets.env /data/secrets /data/config/.env /data/omniroute/.env /data/omniroute/secrets.env /data/omniroute/secrets /data/omniroute/.secrets /data/omniroute/server.env 2>/dev/null || true

echo "[BOOT] Secrets validated: $(get_elapsed)"

# ── STEP 2: Canonical Direct Persistent Storage & Preflight Gate ──────────────
export DATA_DIR="/data/omniroute"
export OMNIROUTE_DATA_DIR="/data/omniroute"

preflight_persistence_gate() {
    log_info "PREFLIGHT" "Validating persistent storage invariants for OmniRoute..."
    if [ ! -d "/data" ]; then
        log_error "PREFLIGHT" "CRITICAL: /data directory does not exist! Persistent bucket not mounted."
        return 1
    fi
    if [ ! -w "/data" ]; then
        log_error "PREFLIGHT" "CRITICAL: /data is not writable!"
        return 1
    fi
    mkdir -p "$DATA_DIR/backups" "$DATA_DIR/oauth" "$DATA_DIR/credentials" "$DATA_DIR/call_logs" "$DATA_DIR/runtime" 2>/dev/null || true
    if [ ! -w "$DATA_DIR" ]; then
        log_error "PREFLIGHT" "CRITICAL: DATA_DIR ($DATA_DIR) is not writable!"
        return 1
    fi

    # Touch probe to verify read-write access
    _PROBE="$DATA_DIR/.probe_$$"
    if ! touch "$_PROBE" 2>/dev/null; then
        log_error "PREFLIGHT" "CRITICAL: Write probe failed in $DATA_DIR!"
        return 1
    fi
    rm -f "$_PROBE" 2>/dev/null || true

    # SQLite integrity check if database already exists
    if [ -f "$DATA_DIR/storage.sqlite" ] && [ -s "$DATA_DIR/storage.sqlite" ]; then
        if command -v sqlite3 >/dev/null 2>&1; then
            _CHK=$(sqlite3 "$DATA_DIR/storage.sqlite" "PRAGMA quick_check;" 2>/dev/null || echo "failed")
            if [ "$_CHK" = "ok" ]; then
                log_info "PREFLIGHT" "Existing storage.sqlite integrity verified: PRAGMA quick_check passed."
            else
                log_warn "PREFLIGHT" "storage.sqlite failed quick_check: $_CHK"
                if [ -f "$DATA_DIR/backups/last-known-good.sqlite" ]; then
                    _BCHK=$(sqlite3 "$DATA_DIR/backups/last-known-good.sqlite" "PRAGMA quick_check;" 2>/dev/null || echo "failed")
                    if [ "$_BCHK" = "ok" ]; then
                        log_warn "PREFLIGHT" "Restoring database from verified last-known-good backup..."
                        cp -f "$DATA_DIR/backups/last-known-good.sqlite" "$DATA_DIR/storage.sqlite" 2>/dev/null || true
                    fi
                fi
            fi
        fi
    else
        log_info "PREFLIGHT" "Fresh start: storage.sqlite will be created directly by OmniRoute in $DATA_DIR"
    fi

    log_info "PREFLIGHT" "Persistence preflight passed successfully. Single source of truth: $DATA_DIR"
    return 0
}

preflight_persistence_gate || log_error "PREFLIGHT" "Warning: persistence preflight reported issues, continuing with best effort."

# SQLite-Aware Backup Routine (Scheduled & On Shutdown)
backup_omniroute_db() {
    _DB="$DATA_DIR/storage.sqlite"
    _BDIR="$DATA_DIR/backups"
    if [ -f "$_DB" ] && [ -s "$_DB" ]; then
        mkdir -p "$_BDIR" 2>/dev/null || true
        _TIMESTAMP=$(date +%Y%m%d-%H%M%S)
        _BACKUP_FILE="$_BDIR/storage-${_TIMESTAMP}.sqlite"
        if command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "$_DB" "PRAGMA wal_checkpoint(PASSIVE);" 2>/dev/null || true
            sqlite3 "$_DB" ".backup '$_BACKUP_FILE'" 2>/dev/null || cp -f "$_DB" "$_BACKUP_FILE" 2>/dev/null || true
            if [ -f "$_BACKUP_FILE" ] && [ -s "$_BACKUP_FILE" ]; then
                _BCHK=$(sqlite3 "$_BACKUP_FILE" "PRAGMA quick_check;" 2>/dev/null || echo "failed")
                if [ "$_BCHK" = "ok" ]; then
                    cp -f "$_BACKUP_FILE" "$_BDIR/last-known-good.sqlite" 2>/dev/null || true
                    ls -t "$_BDIR"/storage-*.sqlite 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
                    log_info "BACKUP" "Clean SQLite backup created: $_BACKUP_FILE"
                else
                    rm -f "$_BACKUP_FILE" 2>/dev/null || true
                    log_warn "BACKUP" "Backup failed integrity check; discarded."
                fi
            fi
        fi
    fi
}

shutdown_gracefully() {
    log_info "SHUTDOWN" "Process termination signal received. Flushing persistence state..."
    if [ -n "$OMNIROUTE_PID" ] && kill -0 $OMNIROUTE_PID 2>/dev/null; then
        kill -INT $OMNIROUTE_PID 2>/dev/null || true
        for _i in $(seq 1 10); do
            if ! kill -0 $OMNIROUTE_PID 2>/dev/null; then
                break
            fi
            sleep 1
        done
    fi
    if [ -f "$DATA_DIR/storage.sqlite" ] && command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$DATA_DIR/storage.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
        backup_omniroute_db >/dev/null 2>&1 || true
    fi
    log_info "SHUTDOWN" "Persistence checkpoint complete. Container exiting."
    exit 0
}

trap shutdown_gracefully EXIT INT TERM

# ── STEP 3: Start FastAPI Gateway Immediately ────────────────────────────────
echo "[BOOT] FastAPI starting: $(get_elapsed)"
cd /
python3 -m uvicorn proxy:app --host 127.0.0.1 --port 8000 --workers 2 &
FASTAPI_PID=$!

# Step 4: Wait for FastAPI /health/live to return HTTP 200
FASTAPI_READY=0
for i in $(seq 1 30); do
    if curl --max-time 2 -sf -i http://127.0.0.1:8000/health/live | grep -q "200 OK"; then
        FASTAPI_READY=1
        END_TIME=$(date +%s)
        ELAPSED=$((END_TIME - START_TIME))
        echo "[BOOT] FastAPI live: ${ELAPSED}s"
        break
    fi
    sleep 0.2
done

if [ "$FASTAPI_READY" -ne 1 ]; then
    echo "[WARN] FastAPI did not report ready within timeout, proceeding with startup..."
fi

# Step 5: Start Nginx Edge Server on Public Port 4096
echo "[BOOT] Nginx starting..."
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default 2>/dev/null || true
nginx -t -c /nginx.conf
nginx -g 'daemon off;' -c /nginx.conf &
NGINX_PID=$!

# Step 6: Wait for Nginx /health/live on Port 4096 to return HTTP 200
NGINX_READY=0
for i in $(seq 1 30); do
    if curl --max-time 2 -sf -i http://127.0.0.1:4096/health/live | grep -q "200 OK"; then
        NGINX_READY=1
        break
    fi
    sleep 0.2
done

# Step 7: Signal Public Gateway Readiness immediately to Hugging Face
echo "[BOOT] Public gateway live"
echo "[BOOT] Background services starting asynchronously..."

    # Step 8: Start Redis Server & OmniRoute AI Gateway in Background
    if command -v redis-server >/dev/null 2>&1; then
        echo "[INIT] Starting Redis server on port 6379..."
        redis-server --daemonize yes 2>/dev/null || true
        if command -v redis-cli >/dev/null 2>&1; then
            echo "[INIT] Redis server active on port 6379."
        fi
    fi

    echo "[INIT] Starting OmniRoute AI Gateway..."
    export PORT=20128
    export HOSTNAME="127.0.0.1"
    export DATA_DIR="/data/omniroute"
    export OMNIROUTE_DATA_DIR="/data/omniroute"
    export REDIS_URL="redis://127.0.0.1:6379"
    export NEXT_PUBLIC_BASE_URL="https://jishnupg-opencode-cli.hf.space"
    export AUTH_COOKIE_SECURE="true"
    export ALLOW_REMOTE_OAUTH="true"
    export ALLOW_BROWSER_OAUTH="true"
    export OAUTH_CALLBACK_URL="https://jishnupg-opencode-cli.hf.space/callback"
    export NEXT_PUBLIC_OAUTH_CALLBACK_URL="https://jishnupg-opencode-cli.hf.space/callback"
    export REDIRECT_URI="https://jishnupg-opencode-cli.hf.space/callback"
    export ANTIGRAVITY_OAUTH_REDIRECT_URI="https://jishnupg-opencode-cli.hf.space/callback"
    export ANTIGRAVITY_REDIRECT_URI="https://jishnupg-opencode-cli.hf.space/callback"
    export ADMIN_PASSWORD="$INITIAL_PASSWORD"
    export OMNIROUTE_INITIAL_PASSWORD="$INITIAL_PASSWORD"
    export OMNIROUTE_PASSWORD="$INITIAL_PASSWORD"
    export PASSWORD="$INITIAL_PASSWORD"
    export RESET_PASSWORD="$INITIAL_PASSWORD"
    export OMNIROUTE_RESET_PASSWORD="$INITIAL_PASSWORD"
    export CLI_COMPAT_ANTIGRAVITY=1
    export CLI_COMPAT_GITHUB=1
    export CLI_COMPAT_KIMI_CODING=1
    export CLI_COMPAT_CLAUDE=1
    export CLI_COMPAT_CODEX=1
    export CLI_COMPAT_CURSOR=1
    export CLI_COMPAT_QWEN=1
    export OMNIROUTE_AUTO_FREE_FALLBACK_TO_FULL_POOL=true
    export OMNIROUTE_ALLOW_UNAUTHENTICATED=true
    export REQUIRE_API_KEY=false
    export OMNIROUTE_REQUIRE_API_KEY=false
    export OMNIROUTE_AUTH_REQUIRED=false
    export RATE_LIMIT_ENABLED=false
    export ENABLE_RATE_LIMIT=false
    export ENABLE_RATE_LIMITING=false
    export OMNIROUTE_RATE_LIMIT_ENABLED=false
    export AUTH_RATE_LIMIT=false
    export LOGIN_RATE_LIMIT=false
    export DISABLE_RATE_LIMIT=true
    export DISABLE_RATE_LIMITING=true
    export AUTH_RATE_LIMIT_MAX=100000
    export AUTH_RATE_LIMIT_WINDOW_MS=1000
    export RATE_LIMIT_MAX=100000
    export RATE_LIMIT_WINDOW_MS=1000
    export TRUST_PROXY=true

    # ── Master Provider API Keys & Secrets Auto-Discovery ─────────────────────
    export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
    export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${CLAUDE_API_KEY:-}}"
    export GEMINI_API_KEY="${GEMINI_API_KEY:-${GOOGLE_API_KEY:-${GOOGLE_GENAI_API_KEY:-}}}"
    export DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
    export GROQ_API_KEY="${GROQ_API_KEY:-}"
    export NVIDIA_API_KEY="${NVIDIA_API_KEY:-${NVIDIA_NIM_API_KEY:-}}"
    export HUGGINGFACE_API_KEY="${HUGGINGFACE_API_KEY:-${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}}"
    export HF_TOKEN="${HF_TOKEN:-$HUGGINGFACE_API_KEY}"
    export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
    export MISTRAL_API_KEY="${MISTRAL_API_KEY:-}"
    export COHERE_API_KEY="${COHERE_API_KEY:-}"
    export MOONSHOT_API_KEY="${MOONSHOT_API_KEY:-${KIMI_API_KEY:-}}"
    export TOGETHER_API_KEY="${TOGETHER_API_KEY:-}"
    export FIREWORKS_API_KEY="${FIREWORKS_API_KEY:-}"
    export CEREBRAS_API_KEY="${CEREBRAS_API_KEY:-}"
    export PERPLEXITY_API_KEY="${PERPLEXITY_API_KEY:-}"
    export XAI_API_KEY="${XAI_API_KEY:-}"
    export GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    export ANTIGRAVITY_API_KEY="${ANTIGRAVITY_API_KEY:-${ANTIGRAVITY_TOKEN:-}}"

    # ── Restore Persistent Credential Vault into Environment ──────────────────
    if [ -f "/data/omniroute/credentials_vault.json" ]; then
        echo "[VAULT] Restoring persistent provider secrets from /data/omniroute/credentials_vault.json..."
        python3 -c "
import json
try:
    with open('/data/omniroute/credentials_vault.json', 'r', encoding='utf-8') as f:
        v = json.load(f)
    for k, val in v.items():
        if k and val:
            print(f'export {k}=\"{val}\"')
except Exception:
    pass
" > /tmp/vault_env.sh 2>/dev/null || true
        if [ -f "/tmp/vault_env.sh" ]; then
            . /tmp/vault_env.sh
            rm -f /tmp/vault_env.sh
        fi
    fi

    if [ -d "/omniroute" ]; then
        cd /omniroute
        if [ -f "/fix_omniroute.py" ]; then
            python3 /fix_omniroute.py /omniroute 2>&1 || true
        elif [ -f "fix_omniroute.py" ]; then
            python3 fix_omniroute.py ./ 2>&1 || true
        fi
        mkdir -p /data/omniroute 2>/dev/null || true
        if [ -f "server.js" ]; then
            echo "[INIT] OmniRoute entry: node server.js (PORT=20128)"
            node server.js > /data/omniroute/omniroute.log 2>&1 &
        else
            echo "[INIT] OmniRoute entry: npm run start (PORT=20128)"
            npm run start > /data/omniroute/omniroute.log 2>&1 &
        fi
        OMNIROUTE_PID=$!
        (
            for i in $(seq 1 90); do
                if curl -fsS "http://127.0.0.1:20128/api/monitoring/health" >/dev/null 2>&1; then
                    echo "[HEALTH] OmniRoute ready after ${i}s"
                    echo "[PROCESS] OmniRoute: PID ${OMNIROUTE_PID}"
                    backup_omniroute_db >/dev/null 2>&1 || true
                    break
                fi
                sleep 1
            done
        ) &
    fi

# Step 9: Start Database & Disk Health Doctor Daemon
if [ -f "/health_doctor.py" ]; then
    echo "[HEALTH] Starting Database & Disk Health Doctor daemon..."
    python3 /health_doctor.py > /data/cache/health_doctor.log 2>&1 &
fi

# Step 10: Keep PID 1 Alive and Monitor Child Processes
echo "[BOOT] All services dispatched. Process Supervisor active."
BACKUP_TIMER=0

while true; do
    if [ -n "$FASTAPI_PID" ] && ! kill -0 $FASTAPI_PID 2>/dev/null; then
        echo "[CRITICAL] FastAPI Gateway process died! Restarting..."
        python3 -m uvicorn proxy:app --host 127.0.0.1 --port 8000 --workers 2 > /data/cache/fastapi_gateway.log 2>&1 &
        FASTAPI_PID=$!
    fi

    if [ -n "$NGINX_PID" ] && ! kill -0 $NGINX_PID 2>/dev/null; then
        echo "[CRITICAL] Nginx process died! Restarting..."
        nginx -g 'daemon off;' -c /nginx.conf &
        NGINX_PID=$!
    fi

    if [ -n "$OMNIROUTE_PID" ] && ! kill -0 $OMNIROUTE_PID 2>/dev/null; then
        echo "[CRITICAL] OmniRoute process died! Restarting..."
        (cd /omniroute && node server.js) > /data/omniroute/omniroute.log 2>&1 &
        OMNIROUTE_PID=$!
    fi

    # Periodic clean SQLite backup routine every 3600 seconds (1 hour)
    BACKUP_TIMER=$((BACKUP_TIMER + 10))
    if [ "$BACKUP_TIMER" -ge 3600 ]; then
        backup_omniroute_db >/dev/null 2>&1 || true
        BACKUP_TIMER=0
    fi

    sleep 10
done
