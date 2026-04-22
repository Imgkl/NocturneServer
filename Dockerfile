# syntax=docker/dockerfile:1.7-labs
# ==============================================================================
# Nocturne - Dockerfile
# Swift Hummingbird Backend + Frontend + ARM64 Cross-Compilation
# Port: 3242
# ==============================================================================

ARG SWIFT_VERSION=6.1
ARG NODE_VERSION=20
ARG UBUNTU_VERSION=jammy
ARG TARGETPLATFORM
ARG BUILDPLATFORM
ARG NOCTURNE_VERSION=dev

# ==============================================================================
# Stage 1: Frontend Build (from frontend/ directory)
# ==============================================================================
FROM node:${NODE_VERSION}-alpine AS frontend-builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache g++ git make python3

# Copy frontend package files
COPY frontend/nocturne-web/package.json frontend/nocturne-web/package-lock.json* ./

# Install dependencies (include devDependencies for build tools)
RUN --mount=type=cache,id=npm-cache,target=/root/.npm \
    npm ci --no-audit --no-fund

# Copy frontend source code
COPY frontend/nocturne-web/ ./

# Build the frontend
ENV NODE_ENV=production
RUN npm run build

# Verify frontend build outputs to /public as configured by Vite
RUN ls -la /public/ && echo "Frontend build completed"

# ==============================================================================
# Stage 2: Swift Backend Build with Cross-Compilation  
# ==============================================================================
FROM swift:${SWIFT_VERSION}-${UBUNTU_VERSION} AS swift-builder

# Install native build dependencies (with robust apt retries)
RUN export DEBIAN_FRONTEND=noninteractive && \
    set -eux; \
    echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries; \
    for i in 1 2 3 4 5; do \
        apt-get update && break || (echo "apt-get update failed, retrying..." && sleep 5); \
    done; \
    apt-get install -y --no-install-recommends \
        binutils \
        build-essential \
        curl \
        libsqlite3-dev \
        libssl-dev \
        pkg-config \
        zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Copy Swift package files
COPY Package.swift Package.resolved* ./

# Resolve Swift dependencies
RUN --mount=type=cache,id=spm-cache,target=/root/.swiftpm \
    --mount=type=cache,id=spm-ccache,target=/root/.cache \
    swift package resolve

# Copy Swift source code
COPY Sources/ ./Sources/

# Build natively for the target platform (buildx/QEMU handles emulation)
ARG TARGETPLATFORM
RUN --mount=type=cache,id=spm-cache,target=/root/.swiftpm \
    --mount=type=cache,id=spm-ccache,target=/root/.cache \
    echo "Building Nocturne for target platform: $TARGETPLATFORM" && \
    swift build --configuration release --product NocturneServer

# Verify, strip and display binary information (single layer)
RUN echo "=== Binary Verification ===" && \
    ls -la .build/release/ && \
    file .build/release/NocturneServer || true && \
    ldd .build/release/NocturneServer 2>/dev/null || echo "Static binary (no dynamic dependencies)" && \
    echo "Binary size: $(stat -c%s .build/release/NocturneServer) bytes" || true && \
    echo "==========================" && \
    strip .build/release/NocturneServer || true && \
    echo "Final binary size: $(stat -c%s .build/release/NocturneServer) bytes" || true

# ==============================================================================
# Stage 3: Production Runtime
# ==============================================================================
FROM swift:${SWIFT_VERSION}-${UBUNTU_VERSION}-slim

# Bring build args into this stage
ARG NOCTURNE_VERSION

# Install runtime dependencies and create user/group (single layer with retries)
RUN export DEBIAN_FRONTEND=noninteractive && \
    set -eux; \
    echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries; \
    for i in 1 2 3 4 5; do \
        apt-get update && break || (echo "apt-get update failed, retrying..." && sleep 5); \
    done; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gosu \
        libsqlite3-0 \
        libssl3 \
        tini \
        tzdata \
        wget \
        zlib1g; \
    rm -rf /var/lib/apt/lists/* && apt-get clean; \
    groupadd -r nocturne; \
    useradd -r -g nocturne -d /app -s /bin/bash -c "Nocturne User" nocturne; \
    echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

# Set working directory
WORKDIR /app

# Create application directory structure
RUN mkdir -p \
        /app/data \
        /app/data/cache/posters \
        /app/config \
        /app/logs \
        /app/public \
        /app/static \
        /app/tmp \
    && chown -R nocturne:nocturne /app

# Copy Swift binary from builder stage
COPY --from=swift-builder --chown=nocturne:nocturne \
    /workspace/.build/release/NocturneServer \
    /app/nocturne-server

# Copy frontend build from frontend builder (Vite outDir -> /public)
COPY --from=frontend-builder --chown=nocturne:nocturne \
    /public/ \
    /app/public/

# Copy static assets from top-level public directory
COPY --chown=nocturne:nocturne public/ /app/static/

# Make binary executable
RUN chmod +x /app/nocturne-server

# Entrypoint script: fixes bind-mount ownership then drops privileges to nocturne
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Environment variables for Nocturne
ENV NOCTURNE_HOST=0.0.0.0
ENV NOCTURNE_PORT=3242
ENV WEBUI_PORT=3242
ENV NOCTURNE_DATABASE_PATH=/app/data/nocturne.sqlite
ENV NOCTURNE_VERSION=${NOCTURNE_VERSION}

# Swift runtime optimizations
ENV SWIFT_DETERMINISTIC_HASHING=1
ENV SWIFT_MAX_MALLOC_SIZE=128MB

# Timezone (adjust as needed)
ENV TZ=UTC

# Working directory for runtime
WORKDIR /app

# Expose port 3242
EXPOSE 3242

# OCI labels
LABEL org.opencontainers.image.title="Nocturne"
LABEL org.opencontainers.image.description="Self-hosted mood tagging server for Jellyfin with admin web UI"
LABEL org.opencontainers.image.vendor="Nocturne Project"
LABEL org.opencontainers.image.port="3242"
LABEL org.opencontainers.image.version="${NOCTURNE_VERSION}"

# Health check configuration
HEALTHCHECK --interval=30s \
            --timeout=10s \
            --start-period=60s \
            --retries=3 \
    CMD curl -f http://localhost:3242/health || exit 1

# Volume declarations for persistent data
VOLUME ["/app/data", "/app/config", "/app/logs"]

# Use tini as init system for proper signal handling; entrypoint script drops to nocturne user
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]

# Default command to run the server
CMD ["/app/nocturne-server"]
