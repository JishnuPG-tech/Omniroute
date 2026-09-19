# ==============================================================================
# STAGE 1: Extract prebuilt OmniRoute production runtime
# No source compilation. No npm install. No Next.js build. No OOM.
# ==============================================================================
FROM diegosouzapw/omniroute:main AS omniroute-source

# ==============================================================================
# STAGE 2: Final Multi-Service Production Runtime
# Assembles all services using prebuilt artifacts only.
# ==============================================================================
FROM debian:bookworm-slim

ENV XDG_DATA_HOME=/data/share
ENV XDG_CONFIG_HOME=/data/config
ENV XDG_CACHE_HOME=/root/.cache
ENV XDG_STATE_HOME=/data/state
ENV DATA_DIR=/data/omniroute
ENV OMNIROUTE_DATA_DIR=/data/omniroute
ENV HOME=/root

# 1. Install runtime system packages only — no build toolchain for OmniRoute
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    python3 \
    python3-pip \
    nginx \
    gnupg \
    sqlite3 \
    redis-server \
 && rm -rf /var/lib/apt/lists/*

# 2. Install core Python runtime dependencies for Gateway
RUN pip3 install --no-cache-dir \
    aiohttp httpx uvicorn fastapi huggingface_hub \
    --break-system-packages

# 4. Copy prebuilt OmniRoute production runtime from Stage 1
#    /app inside the upstream image contains the complete standalone production server:
#    .next/, server.js (or package.json start script), node_modules/, and Node binary
COPY --from=omniroute-source /app /omniroute

# 5. Copy Node.js runtime from the OmniRoute image (avoids manual curl download)
COPY --from=omniroute-source /usr/local/bin/node /usr/local/bin/node
COPY --from=omniroute-source /usr/local/bin/npm  /usr/local/bin/npm
COPY --from=omniroute-source /usr/local/bin/npx  /usr/local/bin/npx
COPY --from=omniroute-source /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN mkdir -p /root/.cache /data/cache /data/omniroute
RUN chmod -R 777 /root/.cache /data/cache /omniroute /data/omniroute

# 6. Copy Gateway Proxy Application & Entrypoint Scripts
WORKDIR /
COPY entrypoint.sh /entrypoint.sh
COPY nginx.conf /nginx.conf
COPY proxy.py /proxy.py
COPY fix_omniroute.py /fix_omniroute.py
COPY health_doctor.py /health_doctor.py
COPY vault_sync.py /vault_sync.py
COPY gateway /gateway
COPY index.html /index.html
RUN chmod +x /entrypoint.sh /fix_omniroute.py /health_doctor.py /vault_sync.py

EXPOSE 4096

ENTRYPOINT ["/entrypoint.sh"]
