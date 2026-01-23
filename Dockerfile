# Multi-stage Dockerfile for homelab smoke test runner
# Builds the Go binary and creates a minimal runtime image
# Image pushed to: docker.nexus.erauner.dev/homelab/smoke
#
# Runtime Usage:
#   The smoke binary expects checks and scripts to be mounted at runtime:
#   docker run --rm \
#     -v "$HOME/.kube:/root/.kube:ro" \
#     -v "/path/to/smoke:/checks:ro" \
#     --network host \
#     smoke:latest \
#     --checks="/checks/checks.yaml"

# Build stage
FROM golang:1.25-alpine AS builder

WORKDIR /build

# Install build dependencies
RUN apk add --no-cache git

# Set up Go proxies for private modules
ENV GOPROXY=https://athens.erauner.dev,direct
ENV GONOSUMDB=github.com/erauner/*

# Copy go mod files first for better layer caching
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build the smoke binary
ARG VERSION=dev
ARG COMMIT=unknown
ARG BUILD_DATE=unknown
RUN CGO_ENABLED=0 GOOS=linux go build -buildvcs=false \
    -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT} -X main.date=${BUILD_DATE}" \
    -o /smoke ./cmd/smoke

# Runtime stage
FROM alpine:3.20

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    kubectl

# Create non-root user
RUN adduser -D -u 1000 smoke

# Copy binary from builder
COPY --from=builder /smoke /usr/local/bin/smoke

# Create app directory for mounted content
RUN mkdir -p /app && chown smoke:smoke /app

# Set working directory
WORKDIR /app

# Switch to non-root user
USER smoke

# Default entrypoint
# Checks and scripts should be mounted at /checks
ENTRYPOINT ["/usr/local/bin/smoke"]
CMD ["--help"]
