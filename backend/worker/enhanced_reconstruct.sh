#!/bin/bash
# backend/worker/enhanced_reconstruct.sh

set -euo pipefail

# Configuration
REDIS_URL=${REDIS_URL:-redis://redis:6379/0}
WEBSOCKET_URL=${WEBSOCKET_URL:-ws://websocket:8765}
MAX_WORKERS=${MAX_WORKERS:-2}
RETRY_DELAY=30
HEALTH_CHECK_INTERVAL=60

# Logging
log() {
    echo "[$(date -Is)] [$$] $*" | tee -a /app/logs/worker.log
}

error() {
    echo "[$(date -Is)] [$$] ERROR: $*" | tee -a /app/logs/worker.log
    # Send to monitoring system
    curl -s -X POST "$WEBSOCKET_URL/error" -d "{\"error\": \"$*\"}" || true
}

# Progress reporting function
report_progress() {
    local job_id=$1
    local stage=$2
    local progress=$3
    local message=$4
    
    local payload=$(cat <<EOF
{
    "job_id": "$job_id",
    "stage": "$stage",
    "progress": $progress,
    "message": "$message",
    "timestamp": $(date +%s)
}
EOF
)
    
    # Send to WebSocket and Redis
    curl -s -X POST "$WEBSOCKET_URL/progress" \
         -H "Content-Type: application/json" \
         -d "$payload" || true
    
    echo "$payload" | redis-cli -u "$REDIS_URL" publish "progress:$job_id" || true
}

# Enhanced COLMAP processing with error recovery
process_colmap_job() {
    local job_data=$1
    local job_id=$(echo "$job_data" | jq -r '.job_id')
    local filepath=$(echo "$job_data" | jq -r '.filepath')
    local filename=$(basename "$filepath")
    local base_name="${filename%.*}"
    
    log "Processing job $job_id: $filename"
    
    # Update job status
    echo "$job_data" | jq '.status = "processing" | .started_at = now' | \
        redis-cli -u "$REDIS_URL" set "job:$job_id" || true
    
    # Setup paths
    local scene_out="/app/output_scenes/$base_name"
    local temp_images="/app/temp_images/$job_id"
    
    mkdir -p "$scene_out" "$temp_images"
    
    # Cleanup function
    cleanup_job() {
        rm -rf "$temp_images"
        log "Cleaned up temporary files for job $job_id"
    }
    trap cleanup_job EXIT
    
    # Stage 1: Video to frames
    report_progress "$job_id" "video_extraction" 10 "Extracting frames from video"
    
    if ! timeout 300 ffmpeg -hide_banner -loglevel error -i "$filepath" \
         -vf "scale=1280:-1,fps=2" "$temp_images/frame_%05d.png"; then
        error "FFmpeg failed for job $job_id"
        return 1
    fi
    
    local frame_count=$(ls "$temp_images"/*.png 2>/dev/null | wc -l)
    if [ "$frame_count" -lt 10 ]; then
        error "Insufficient frames extracted ($frame_count) for job $job_id"
        return 1
    fi
    
    log "Extracted $frame_count frames for job $job_id"
    report_progress "$job_id" "video_extraction" 25 "Extracted $frame_count frames"
    
    # Stage 2: Feature extraction
    report_progress "$job_id" "feature_extraction" 30 "Extracting image features"
    
    if ! timeout 600 colmap feature_extractor \
         --database_path "$scene_out/database.db" \
         --image_path "$temp_images" \
         --ImageReader.single_camera 1 \
         --ImageReader.camera_model SIMPLE_RADIAL \
         --SiftExtraction.max_image_size 2000 \
         --SiftExtraction.gpu_index 0; then
        error "Feature extraction failed for job $job_id"
        return 1
    fi
    
    report_progress "$job_id" "feature_extraction" 50 "Feature extraction completed"
    
    # Stage 3: Feature matching
    report_progress "$job_id" "feature_matching" 55 "Matching features between images"
    
    if ! timeout 900 colmap exhaustive_matcher \
         --database_path "$scene_out/database.db" \
         --SiftMatching.gpu_index 0; then
        error "Feature matching failed for job $job_id"
        return 1
    fi
    
    report_progress "$job_id" "feature_matching" 75 "Feature matching completed"
    
    # Stage 4: 3D reconstruction
    report_progress "$job_id" "reconstruction" 80 "Building 3D scene"
    
    mkdir -p "$scene_out/sparse"
    
    if ! timeout 1800 colmap mapper \
         --database_path "$scene_out/database.db" \
         --image_path "$temp_images" \
         --output_path "$scene_out/sparse" \
         --Mapper.ba_refine_principal_point 1 \
         --Mapper.ba_local_max_refinements 3; then
        error "3D reconstruction failed for job $job_id"
        return 1
    fi
    
    # Check if reconstruction succeeded
    if [ ! -d "$scene_out/sparse/0" ] || [ ! -f "$scene_out/sparse/0/cameras.bin" ]; then
        error "No valid 3D reconstruction generated for job $job_id"
        return 1
    fi
    
    report_progress "$job_id" "reconstruction" 90 "3D reconstruction completed"
    
    # Stage 5: Queue for Blender processing
    local blender_job_data=$(cat <<EOF
{
    "job_id": "$job_id",
    "scene_path": "$scene_out",
    "output_path": "/app/output_blend/${base_name}.blend",
    "status": "queued_blender",
    "colmap_completed_at": $(date +%s)
}
EOF
)
    
    echo "$blender_job_data" | redis-cli -u "$REDIS_URL" lpush "blender_jobs" || true
    echo "$blender_job_data" | redis-cli -u "$REDIS_URL" set "job:$job_id" || true
    
    report_progress "$job_id" "queued_blender" 95 "Queued for Blender processing"
    
    log "COLMAP processing completed for job $job_id"
    return 0
}

# Worker health monitoring
monitor_worker_health() {
    while true; do
        # Check GPU memory
        local gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | head -1)
        
        # Check disk space
        local disk_usage=$(df /app | tail -1 | awk '{print $5}' | sed 's/%//')
        
        # Report metrics
        curl -s -X POST "$WEBSOCKET_URL/metrics" \
             -H "Content-Type: application/json" \
             -d "{\"gpu_memory\": $gpu_mem, \"gpu_util\": $gpu_util, \"disk_usage\": $disk_usage}" || true
        
        # Cleanup old files if disk usage is high
        if [ "$disk_usage" -gt 80 ]; then
            log "High disk usage ($disk_usage%), cleaning up old files"
            find /app/temp_images -type d -mtime +1 -exec rm -rf {} + || true
            find /app/output_scenes -name "*.jpg" -mtime +7 -delete || true
        fi
        
        sleep "$HEALTH_CHECK_INTERVAL"
    done
}

# Main worker loop with retry mechanism
main_worker_loop() {
    log "Starting enhanced COLMAP worker (PID: $$)"
    
    # Start health monitoring in background
    monitor_worker_health &
    local health_pid=$!
    
    # Cleanup on exit
    trap "kill $health_pid 2>/dev/null || true; exit 0" EXIT
    
    while true; do
        # Get job from queue with timeout
        local job_result=$(redis-cli -u "$REDIS_URL" brpop "colmap_jobs" 30 2>/dev/null || echo "")
        
        if [ -z "$job_result" ]; then
            # No jobs available, continue waiting
            continue
        fi
        
        # Parse job data
        local job_data=$(echo "$job_result" | sed 's/^colmap_jobs //')
        local job_id=$(echo "$job_data" | jq -r '.job_id // empty')
        local retries=$(echo "$job_data" | jq -r '.retries // 0')
        local max_retries=$(echo "$job_data" | jq -r '.max_retries // 3')
        
        if [ -z "$job_id" ]; then
            error "Invalid job data received"
            continue
        fi
        
        log "Processing job $job_id (attempt $((retries + 1)))"
        
        # Process job with error handling
        if process_colmap_job "$job_data"; then
            log "Job $job_id completed successfully"
            # Update metrics
            redis-cli -u "$REDIS_URL" decr "active_jobs_count" || true
        else
            # Job failed, handle retry logic
            local new_retries=$((retries + 1))
            
            if [ "$new_retries" -lt "$max_retries" ]; then
                log "Job $job_id failed, retrying ($new_retries/$max_retries)"
                
                # Update job with new retry count and delay
                local retry_job_data=$(echo "$job_data" | jq --argjson retries "$new_retries" '.retries = $retries | .status = "retry" | .last_error = now')
                
                # Re-queue with delay
                sleep "$RETRY_DELAY"
                echo "$retry_job_data" | redis-cli -u "$REDIS_URL" lpush "colmap_jobs" || true
                
                report_progress "$job_id" "retry" 0 "Job failed, retrying in ${RETRY_DELAY}s (attempt $new_retries/$max_retries)"
            else
                error "Job $job_id failed after $max_retries attempts"
                
                # Mark as failed
                local failed_job_data=$(echo "$job_data" | jq '.status = "failed" | .failed_at = now')
                echo "$failed_job_data" | redis-cli -u "$REDIS_URL" set "job:$job_id" || true
                
                report_progress "$job_id" "failed" 0 "Job failed after maximum retries"
                
                # Move to failed queue for manual inspection
                echo "$failed_job_data" | redis-cli -u "$REDIS_URL" lpush "failed_jobs" || true
            fi
        fi
        
        # Brief pause between jobs
        sleep 5
    done
}

# Start worker
main_worker_loop