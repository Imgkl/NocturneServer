SHELL := /bin/bash

# Git tag for versioning Docker images (fallback to "dev" if no tags)
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null || echo dev)

.PHONY: web build package docker clean

web:
	cd frontend/nocturne-web && npm ci && npm run build && rm -rf ../../public && mkdir -p ../../public && cp -R dist/* ../../public

build:
	swift build -c release

package: web build
	mkdir -p release && cp .build/release/NocturneServer release/ && cp -R public release/public

docker:
	docker build --build-arg NOCTURNE_VERSION=$(VERSION) -t nocturne-server:$(VERSION) -t nocturne-server:latest .

clean:
	rm -rf .build public release nocturne.sqlite secrets

.PHONY: build run test clean docker-build docker-run setup migrate sync check fmt

# Default target
all: build

# Build the application
build:
	@echo "🔨 Building Nocturne..."
	swift build -c release

# Build for development
build-dev:
	@echo "🔨 Building for development..."
	swift build

# Run the server
run: build-dev
	@echo "🚀 Starting server..."
	./.build/debug/NocturneServer

# Frontend (React + Vite)
fe-install:
	@echo "📦 Installing frontend deps..."
	cd frontend/nocturne-web && npm install

fe-dev:
	@echo "▶️  Starting Vite dev server (proxy to :8003)..."
	cd frontend/nocturne-web && npm run dev

fe-build:
	@echo "🏗️  Building frontend into public/ ..."
	cd frontend/nocturne-web && npm run build

# Run with verbose logging  
run-verbose: build-dev
	@echo "🚀 Starting server..."
	./.build/debug/NocturneServer

# Setup development environment
setup:
	@echo "⚙️ Setting up development environment..."
	@if [ ! -f config.yaml ]; then \
		echo "📝 Creating config file..."; \
		cp config.example.yaml config.yaml; \
		echo "✏️ Server will show setup wizard on first run"; \
	fi
	@mkdir -p data logs public
	@echo "✅ Setup complete!"

# Clean build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	swift package clean
	rm -rf .build

# Format code
fmt:
	@echo "🎨 Formatting code..."
	swift-format --in-place --recursive Sources/

# Lint code
lint:
	@echo "🔍 Linting code..."
	swiftlint lint Sources/

# Run unit tests
test-unit:
	@echo "🧪 Running unit tests..."
	swift test

# Docker commands
docker-build:
	@echo "🐳 Building Docker image..."
	docker build --build-arg NOCTURNE_VERSION=$(VERSION) -t nocturne-server:$(VERSION) -t nocturne-server:latest .

docker-build-pi:
	@echo "🫐 Building Docker image for Raspberry Pi (ARM64)..."
	docker buildx build --platform linux/arm64 --build-arg NOCTURNE_VERSION=$(VERSION) -t nocturne-server:arm64-$(VERSION) -t nocturne-server:arm64-latest .

docker-run: docker-build
	@echo "🐳 Running Docker container..."
	docker compose up -d

# Pi deployment
deploy-pi:
	@echo "🫐 Deploying to Raspberry Pi..."
	chmod +x deploy-pi.sh
	./deploy-pi.sh

# Production deployment with multi-arch support
deploy-prod:
	@echo "🚀 Building multi-architecture images..."
	docker buildx create --use --name nocturne-builder || true
	docker buildx build --platform linux/amd64,linux/arm64 --build-arg NOCTURNE_VERSION=$(VERSION) -t nocturne-server:$(VERSION) -t nocturne-server:latest --push .
	docker compose -f docker-compose.prod.yml up -d

docker-logs:
	@echo "📋 Showing Docker logs..."
	docker compose logs -f nocturne

docker-stop:
	@echo "🛑 Stopping Docker containers..."
	docker compose down

docker-clean:
	@echo "🧹 Cleaning Docker containers and images..."
	docker compose down --volumes --remove-orphans
	docker rmi nocturne-server:latest 2>/dev/null || true

# Health check
health:
	@echo "❤️ Checking server health..."
	@curl -f http://localhost:8001/health && echo "✅ Server is healthy" || echo "❌ Server is not responding"

# API examples
api-test:
	@echo "🧪 Testing API endpoints..."
	@echo "Health check:"
	@curl -s http://localhost:8001/health
	@echo "\n\nMood buckets:"
	@curl -s http://localhost:8001/api/v1/moods | jq '.moods | keys'
	@echo "\n\nMovies count:"
	@curl -s http://localhost:8001/api/v1/movies | jq '.totalCount'

# Development workflow
dev: setup
	@echo "🎯 Development environment ready!"
	@echo "Run 'make run' to start the server"
	@echo "Visit http://localhost:8001 for setup wizard or dashboard"

# Production deployment
deploy: docker-build
	@echo "🚀 Deploying to production..."
	docker compose -f docker-compose.prod.yml up -d

# Show help
help:
	@echo "Nocturne - Available Commands:"
	@echo ""
	@echo "Development:"
	@echo "  setup       - Setup development environment"
	@echo "  build       - Build release binary"
	@echo "  build-dev   - Build debug binary"
	@echo "  run         - Run development server"
	@echo "  dev         - Complete dev setup"
	@echo ""
	@echo "Web Interface:"
	@echo "  Server automatically handles setup, migrations, and sync"
	@echo "  Visit http://localhost:8001 after starting server"
	@echo ""
	@echo "Docker:"
	@echo "  docker-build   - Build Docker image"
	@echo "  docker-build-pi - Build ARM64 image for Pi"
	@echo "  docker-run     - Run with Docker Compose"
	@echo "  docker-logs    - Show Docker logs"
	@echo "  docker-stop    - Stop Docker containers"
	@echo "  docker-clean   - Clean Docker resources"
	@echo ""
	@echo "Raspberry Pi:"
	@echo "  deploy-pi      - One-click Pi deployment"
	@echo ""
	@echo "Code Quality:"
	@echo "  fmt         - Format Swift code"
	@echo "  lint        - Lint Swift code"
	@echo "  clean       - Clean build artifacts"
	@echo ""
	@echo "Production:"
	@echo "  deploy      - Deploy to production"
