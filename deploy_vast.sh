#!/bin/bash
# deploy_vast.sh - Automated Vast.ai deployment script

set -euo pipefail

# Configuration
INSTANCE_TYPE="rtx4090"
MIN_RAM_GB=32
MIN_VCPUS=8
MIN_DISK_GB=100
MAX_PRICE_PER_HOUR="0.25"
IMAGE="pytorch/pytorch:2.1.0-cuda12.1-cudnn8-devel"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Install vast CLI if not exists
install_vast_cli() {
    if ! command -v vast &> /dev/null; then
        log "Installing Vast.ai CLI..."
        pip install vastai
    fi
}

# Search for optimal instance
search_instance() {
    log "Searching for optimal GPU instance..."
    
    vast search offers \
        "gpu_name=${INSTANCE_TYPE} ram_gb>=${MIN_RAM_GB} cpu_cores>=${MIN_VCPUS} disk_space>=${MIN_DISK_GB} dph<=${MAX_PRICE_PER_HOUR}" \
        --order dph | head -10 > available_instances.txt
    
    if [ ! -s available_instances.txt ]; then
        error "No suitable instances found with your criteria"
    fi
    
    log "Found $(wc -l < available_instances.txt) suitable instances"
    cat available_instances.txt
}

# Create instance
create_instance() {
    log "Creating Vast.ai instance..."
    
    INSTANCE_ID=$(vast create instance $(head -1 available_instances.txt | awk '{print $1}') \
        --image "${IMAGE}" \
        --disk 100 \
        --ssh | grep "Started" | awk '{print $3}')
    
    if [ -z "$INSTANCE_ID" ]; then
        error "Failed to create instance"
    fi
    
    log "Instance created with ID: $INSTANCE_ID"
    echo "$INSTANCE_ID" > instance_id.txt
}

# Wait for instance to be ready
wait_for_instance() {
    log "Waiting for instance to be ready..."
    
    while true; do
        STATUS=$(vast show instance $INSTANCE_ID | grep "actual_status" | awk '{print $2}')
        if [ "$STATUS" = "running" ]; then
            break
        fi
        log "Instance status: $STATUS. Waiting..."
        sleep 30
    done
    
    log "Instance is ready!"
}

# Setup instance
setup_instance() {
    INSTANCE_ID=$(cat instance_id.txt)
    SSH_CMD=$(vast ssh-url $INSTANCE_ID)
    
    log "Setting up instance..."
    
    # Upload deployment files
    scp -r . $SSH_CMD:/root/3d-tracker/
    
    # Execute setup commands
    ssh $SSH_CMD << 'EOF'
        cd /root/3d-tracker
        
        # Update system
        apt-get update && apt-get install -y docker.io docker-compose
        systemctl start docker
        
        # Create environment file
        cat > .env << 'ENV'
MINIO_PASSWORD=supersecretpassword123
SENTRY_DSN=your_sentry_dsn_here
GRAFANA_PASSWORD=admin123
ENV
        
        # Create required directories
        mkdir -p input_videos output_scenes output_blend tmp logs ssl
        chmod 777 input_videos output_scenes output_blend tmp logs
        
        # Start services
        docker-compose -f docker-compose.prod.yml up -d
        
        # Wait for services
        sleep 60
        
        # Check health
        docker-compose -f docker-compose.prod.yml ps
EOF
    
    log "Setup complete!"
    
    # Get instance IP
    INSTANCE_IP=$(vast show instance $INSTANCE_ID | grep "ssh_host" | awk '{print $2}')
    
    log "Instance deployed successfully!"
    log "API URL: http://$INSTANCE_IP:8000"
    log "Grafana Dashboard: http://$INSTANCE_IP:3000"
    log "MinIO Console: http://$INSTANCE_IP:9001"
    log "SSH: $SSH_CMD"
}

# Cost optimization monitoring
setup_cost_monitoring() {
    log "Setting up cost monitoring..."
    
    cat > cost_monitor.sh << 'EOF'
#!/bin/bash
# Cost monitoring and auto-shutdown script

INSTANCE_ID=$(cat instance_id.txt)
MAX_HOURLY_COST=0.50
MAX_IDLE_TIME=3600  # 1 hour

while true; do
    # Get current cost
    CURRENT_COST=$(vast show instance $INSTANCE_ID | grep "dph_total" | awk '{print $2}')
    
    # Check if cost exceeds threshold
    if (( $(echo "$CURRENT_COST > $MAX_HOURLY_COST" | bc -l) )); then
        echo "Cost threshold exceeded: $CURRENT_COST/hour"
        # Send alert (implement your notification method)
        # curl -X POST webhook_url -d "Cost alert: $CURRENT_COST/hour"
    fi
    
    # Check for idle containers
    IDLE_TIME=$(docker stats --no-stream --format "table {{.CPUPerc}}" | tail -n +2 | head -1)
    if [[ "$IDLE_TIME" =~ 0.0* ]]; then
        echo "System appears idle. Consider shutting down to save costs."
    fi
    
    sleep 300  # Check every 5 minutes
done
EOF
    
    chmod +x cost_monitor.sh
    nohup ./cost_monitor.sh > cost_monitor.log 2>&1 &
}

# Main execution
main() {
    log "Starting Vast.ai deployment for 3D Tracker..."
    
    install_vast_cli
    search_instance
    
    read -p "Do you want to create the best instance? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        create_instance
        wait_for_instance
        setup_instance
        setup_cost_monitoring
    else
        log "Deployment cancelled."
        exit 0
    fi
}

# Cleanup function
cleanup() {
    if [ -f instance_id.txt ]; then
        INSTANCE_ID=$(cat instance_id.txt)
        log "Destroying instance $INSTANCE_ID..."
        vast destroy instance $INSTANCE_ID
    fi
}

# Register cleanup function
trap cleanup EXIT

# Run main function
main "$@"