#!/bin/bash
# scripts/cost_optimizer.sh

set -euo pipefail

COST_THRESHOLD=${COST_THRESHOLD:-0.50}  # Max $0.50/hour
IDLE_THRESHOLD=${IDLE_THRESHOLD:-900}   # 15 minutes
CHECK_INTERVAL=${CHECK_INTERVAL:-300}   # 5 minutes

log() {
    echo "[$(date -Is)] COST_OPTIMIZER: $*"
}

check_gpu_utilization() {
    nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | head -1
}

check_queue_size() {
    redis-cli -u "$REDIS_URL" llen "colmap_jobs" 2>/dev/null || echo "0"
}

check_active_jobs() {
    redis-cli -u "$REDIS_URL" llen "blender_jobs" 2>/dev/null || echo "0"
}

scale_down_check() {
    local gpu_util=$(check_gpu_utilization)
    local queue_size=$(check_queue_size)
    local active_jobs=$(check_active_jobs)
    
    log "GPU Utilization: ${gpu_util}%, Queue: $queue_size, Active: $active_jobs"
    
    # Check if system is idle
    if [ "$gpu_util" -lt 5 ] && [ "$queue_size" -eq 0 ] && [ "$active_jobs" -eq 0 ]; then
        local current_time=$(date +%s)
        local last_idle_file="/tmp/last_idle_time"
        
        if [ -f "$last_idle_file" ]; then
            local last_idle_time=$(cat "$last_idle_file")
            local idle_duration=$((current_time - last_idle_time))
            
            if [ "$idle_duration" -gt "$IDLE_THRESHOLD" ]; then
                log "System idle for $idle_duration seconds. Consider scaling down."
                
                # Send notification (implement your notification method)
                # send_slack_notification "3D Tracker system idle for ${idle_duration}s. Consider shutting down to save costs."
                
                # Auto-shutdown if configured
                if [ "${AUTO_SHUTDOWN:-false}" = "true" ]; then
                    log "Auto-shutdown enabled. Shutting down system."
                    shutdown_system
                fi
            fi
        else
            echo "$current_time" > "$last_idle_file"
        fi
    else
        # System is active, remove idle marker
        rm -f "/tmp/last_idle_time"
    fi
}

cleanup_old_files() {
    local temp_dir="/app/temp_images"
    local output_dir="/app/output_scenes"
    
    # Clean files older than 24 hours
    find "$temp_dir" -type f -mtime +1 -delete 2>/dev/null || true
    find "$output_dir" -name "*.jpg" -mtime +7 -delete 2>/dev/null || true
    
    # Clean empty directories
    find "$temp_dir" -type d -empty -delete 2>/dev/null || true
    
    log "Cleaned up old files"
}

optimize_containers() {
    # Restart containers if memory usage is high
    local api_memory=$(docker stats --no-stream --format "table {{.MemUsage}}" tracker_api_prod | tail -1 | awk '{print $1}' | sed 's/MiB//')
    
    if [ "${api_memory:-0}" -gt 800 ]; then
        log "High memory usage detected. Restarting API container."
        docker restart tracker_api_prod
    fi
}

shutdown_system() {
    log "Initiating system shutdown to save costs..."
    
    # Gracefully stop services
    docker-compose -f docker-compose.prod.yml down
    
    # If on Vast.ai, destroy instance
    if [ -f "instance_id.txt" ]; then
        local instance_id=$(cat instance_id.txt)
        vast destroy instance "$instance_id" || true
    fi
    
    # Otherwise, just shutdown the machine
    sudo shutdown -h now
}

# Main monitoring loop
main() {
    log "Starting cost optimization monitoring..."
    
    while true; do
        # Check system utilization and costs
        scale_down_check
        
        # Cleanup old files
        cleanup_old_files
        
        # Optimize container resources
        optimize_containers
        
        # Sleep until next check
        sleep "$CHECK_INTERVAL"
    done
}

# Handle signals
trap 'log "Shutting down cost optimizer..."; exit 0' SIGINT SIGTERM

# Run main function
main "$@"