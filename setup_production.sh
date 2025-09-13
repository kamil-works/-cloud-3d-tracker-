#!/bin/bash
# setup_production.sh - One-click production setup

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# Check if running on Vast.ai
check_vast_ai() {
    if [ -f "/etc/vastai_kaalia" ] || [ -n "${VAST_CONTAINERD:-}" ]; then
        log "Detected Vast.ai environment"
        export IS_VAST_AI=true
    else
        log "Running on standard environment"
        export IS_VAST_AI=false
    fi
}

# Install dependencies
install_dependencies() {
    log "Installing system dependencies..."
    
    apt-get update
    apt-get install -y \
        curl \
        wget \
        git \
        docker.io \
        docker-compose \
        nginx \
        htop \
        nvtop \
        redis-tools \
        jq \
        bc \
        unzip
    
    # Install Docker Compose v2 if not available
    if ! command -v docker-compose &> /dev/null; then
        curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    
    systemctl enable docker
    systemctl start docker
    
    log "Dependencies installed successfully"
}

# Setup NVIDIA container runtime
setup_nvidia_runtime() {
    if ! command -v nvidia-smi &> /dev/null; then
        warn "NVIDIA drivers not found. GPU acceleration will not be available."
        return 0
    fi
    
    log "Setting up NVIDIA container runtime..."
    
    # Install nvidia-container-runtime if not present
    if ! docker info | grep -q nvidia; then
        distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
        curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
        curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list
        
        apt-get update
        apt-get install -y nvidia-container-runtime
        
        # Configure Docker daemon
        cat > /etc/docker/daemon.json << EOF
{
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF
        
        systemctl restart docker
    fi
    
    log "NVIDIA runtime configured"
}

# Create directory structure
create_directories() {
    log "Creating directory structure..."
    
    local dirs=(
        "input_videos"
        "output_scenes" 
        "output_blend"
        "tmp"
        "logs"
        "ssl"
        "monitoring/dashboards"
        "backup"
    )
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        chmod 755 "$dir"
    done
    
    # Set permissions for worker directories
    chmod 777 input_videos output_scenes output_blend tmp
    
    log "Directory structure created"
}

# Generate configuration files
generate_config() {
    log "Generating configuration files..."
    
    # Generate random passwords
    local minio_password=$(openssl rand -base64 32)
    local grafana_password=$(openssl rand -base64 16)
    local redis_password=$(openssl rand -base64 24)
    
    # Create environment file
    cat > .env << EOF
# Production Environment Configuration
NODE_ENV=production
MINIO_PASSWORD=${minio_password}
GRAFANA_PASSWORD=${grafana_password}
REDIS_PASSWORD=${redis_password}
SENTRY_DSN=${SENTRY_DSN:-}
MAX_UPLOAD_SIZE=2147483648
MAX_QUEUE_SIZE=20
AUTO_SHUTDOWN=${AUTO_SHUTDOWN:-false}
COST_THRESHOLD=0.50
IDLE_THRESHOLD=1800
WEBSOCKET_URL=ws://localhost:8765
EOF
    
    # Create Redis configuration
    cat > redis.conf << EOF
# Redis Configuration
bind 0.0.0.0
port 6379
requirepass ${redis_password}
maxmemory 256mb
maxmemory-policy allkeys-lru
save 900 1
save 300 10
save 60 10000
EOF
    
    # Create Nginx configuration
    mkdir -p nginx
    cat > nginx/nginx.conf << EOF
events {
    worker_connections 1024;
}

http {
    upstream api {
        server api:8000;
    }
    
    upstream grafana {
        server grafana:3000;
    }
    
    upstream websocket {
        server websocket:8765;
    }
    
    server {
        listen 80;
        client_max_body_size 2G;
        
        location / {
            proxy_pass http://api;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
        
        location /ws {
            proxy_pass http://websocket;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
        }
        
        location /grafana/ {
            proxy_pass http://grafana/;
            proxy_set_header Host \$host;
        }
    }
}
EOF
    
    cat > nginx/Dockerfile << EOF
FROM nginx:alpine
COPY nginx.conf /etc/nginx/nginx.conf
EXPOSE 80
EOF
    
    log "Configuration files generated"
    log "MinIO Password: ${minio_password}"
    log "Grafana Password: ${grafana_password}"
    log "Redis Password: ${redis_password}"
}

# Setup monitoring dashboards
setup_monitoring() {
    log "Setting up monitoring dashboards..."
    
    # Create Grafana dashboard
    mkdir -p monitoring/dashboards
    cat > monitoring/dashboards/3d-tracker.json << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "3D Tracker Pipeline",
    "tags": ["3d-tracker"],
    "timezone": "browser",
    "panels": [
      {
        "id": 1,
        "title": "Active Jobs",
        "type": "stat",
        "targets": [
          {
            "expr": "active_jobs_total",
            "refId": "A"
          }
        ],
        "gridPos": {"h": 8, "w": 6, "x": 0, "y": 0}
      },
      {
        "id": 2,
        "title": "Queue Size",
        "type": "stat", 
        "targets": [
          {
            "expr": "queue_size_total",
            "refId": "A"
          }
        ],
        "gridPos": {"h": 8, "w": 6, "x": 6, "y": 0}
      },
      {
        "id": 3,
        "title": "GPU Utilization",
        "type": "graph",
        "targets": [
          {
            "expr": "nvidia_gpu_utilization",
            "refId": "A"
          }
        ],
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 8}
      },
      {
        "id": 4,
        "title": "Processing Time",
        "type": "graph",
        "targets": [
          {
            "expr": "api_request_duration_seconds",
            "refId": "A"
          }
        ],
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 8}
      }
    ],
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "refresh": "10s"
  }
}
EOF
    
    # Create Grafana provisioning
    mkdir -p monitoring/grafana/provisioning/{dashboards,datasources}
    
    cat > monitoring/grafana/provisioning/datasources/prometheus.yml << EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF
    
    cat > monitoring/grafana/provisioning/dashboards/dashboards.yml << EOF
apiVersion: 1
providers:
  - name: '3d-tracker'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /var/lib/grafana/dashboards
EOF
    
    log "Monitoring setup completed"
}

# Build and start services
start_services() {
    log "Building and starting services..."
    
    # Pull base images first to save time
    docker pull nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04
    docker pull ubuntu:22.04
    docker pull redis:7-alpine
    docker pull minio/minio:RELEASE.2025-01-01T00-00-00Z
    docker pull prom/prometheus:latest
    docker pull grafana/grafana:latest
    
    # Build and start services
    docker-compose -f docker-compose.prod.yml up -d --build
    
    # Wait for services to be ready
    log "Waiting for services to start..."
    sleep 30
    
    # Health check
    local retries=0
    while [ $retries -lt 30 ]; do
        if curl -f http://localhost:8000/health > /dev/null 2>&1; then
            log "API service is ready"
            break
        fi
        sleep 5
        retries=$((retries + 1))
    done
    
    if [ $retries -eq 30 ]; then
        error "API service failed to start"
    fi
    
    log "All services started successfully"
}

# Setup cost monitoring
setup_cost_monitoring() {
    log "Setting up cost monitoring..."
    
    # Create cost monitoring script
    cp scripts/cost_optimizer.sh /usr/local/bin/cost_optimizer
    chmod +x /usr/local/bin/cost_optimizer
    
    # Create systemd service
    cat > /etc/systemd/system/cost-optimizer.service << EOF
[Unit]
Description=3D Tracker Cost Optimizer
After=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=$(pwd)
Environment=REDIS_URL=redis://localhost:6379/0
ExecStart=/usr/local/bin/cost_optimizer
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable cost-optimizer.service
    systemctl start cost-optimizer.service
    
    log "Cost monitoring service started"
}

# Setup backup system
setup_backup() {
    log "Setting up backup system..."
    
    mkdir -p backup/scripts
    
    cat > backup/scripts/backup_data.sh << 'EOF'
#!/bin/bash
# Automated backup script

BACKUP_DIR="/app/backup"
DATE=$(date +%Y%m%d_%H%M%S)

# Backup important data
tar -czf "$BACKUP_DIR/scenes_$DATE.tar.gz" /app/output_scenes/
tar -czf "$BACKUP_DIR/blend_$DATE.tar.gz" /app/output_blend/
tar -czf "$BACKUP_DIR/logs_$DATE.tar.gz" /app/logs/

# Keep only last 7 days of backups
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +7 -delete

# If on cloud, sync to S3 (optional)
# aws s3 sync "$BACKUP_DIR" s3://your-backup-bucket/3d-tracker/
EOF
    
    chmod +x backup/scripts/backup_data.sh
    
    # Setup cron job for daily backups
    (crontab -l 2>/dev/null; echo "0 2 * * * $(pwd)/backup/scripts/backup_data.sh") | crontab -
    
    log "Backup system configured"
}

# Display final information
show_final_info() {
    local ip_address=$(curl -s ifconfig.me 2>/dev/null || echo "localhost")
    
    log "🎉 3D Tracker Production Setup Complete!"
    echo
    echo -e "${BLUE}Access URLs:${NC}"
    echo "  🚀 API:       http://${ip_address}:8000"
    echo "  📊 Grafana:   http://${ip_address}:3000"
    echo "  💾 MinIO:     http://${ip_address}:9001"
    echo "  📈 Prometheus: http://${ip_address}:9090"
    echo
    echo -e "${BLUE}Credentials:${NC}"
    echo "  Grafana: admin / $(grep GRAFANA_PASSWORD .env | cut -d'=' -f2)"
    echo "  MinIO:   minioadmin / $(grep MINIO_PASSWORD .env | cut -d'=' -f2)"
    echo
    echo -e "${BLUE}Useful Commands:${NC}"
    echo "  📋 View logs:     docker-compose -f docker-compose.prod.yml logs -f"
    echo "  📊 Check status:  docker-compose -f docker-compose.prod.yml ps"
    echo "  🔄 Restart:       docker-compose -f docker-compose.prod.yml restart"
    echo "  🛑 Stop:          docker-compose -f docker-compose.prod.yml down"
    echo
    echo -e "${BLUE}Monitoring:${NC}"
    echo "  💰 Cost optimizer running as systemd service"
    echo "  📈 Metrics available at /metrics endpoints"
    echo "  🔔 Alerts configured in Prometheus"
    echo
    echo -e "${GREEN}System ready for 3D reconstruction workloads!${NC}"
}

# Main setup function
main() {
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     3D Tracker Production Setup     ║${NC}"
    echo -e "${GREEN}║      Vast.ai Optimized Version      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Check environment
    check_vast_ai
    
    # Install dependencies
    install_dependencies
    setup_nvidia_runtime
    
    # Setup application
    create_directories
    generate_config
    setup_monitoring
    
    # Start services
    start_services
    
    # Setup additional features
    setup_cost_monitoring
    setup_backup
    
    # Show final information
    show_final_info
    
    log "Setup completed successfully!"
}

# Error handling
trap 'error "Setup failed at line $LINENO"' ERR

# Run main setup
main "$@"