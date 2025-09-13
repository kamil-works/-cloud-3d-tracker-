
# 🚀 Production 3D Tracker - Deployment Guide

## Quick Start (Vast.ai)

1. **Search for GPU instance:**
   ```bash
   vast search offers "gpu_name=RTX4090 ram_gb>=32 cpu_cores>=8 disk_space>=100 dph<=0.25"

1.Create instance:
vast create instance INSTANCE_ID --image pytorch/pytorch:2.1.0-cuda12.1-cudnn8-devel --disk 100

2.Deploy system:
git clone <your-repo>
cd 3d-tracker-project
chmod +x setup_production.sh
./setup_production.sh

Manual Deployment Steps
1.System Requirements:
GPU: RTX 4090 (24GB VRAM) or RTX 3090
RAM: 32-64GB
Storage: 100GB+ NVMe SSD
OS: Ubuntu 22.04

2.Installation:
# Install dependencies
apt update && apt install -y docker.io docker-compose nvidia-container-runtime

# Setup directories
mkdir -p input_videos output_scenes output_blend tmp logs

# Configure environment
cp .env.example .env
# Edit .env with your settings

# Start services
docker-compose -f docker-compose.prod.yml up -d

3.Verification:
# Check all services are running
docker-compose ps

# Test API
curl http://localhost:8000/health

# Check GPU availability
nvidia-smi

Cost Optimization Features
Auto-scaling: Automatically scale workers based on queue size
Idle detection: Shutdown after configurable idle time
Resource monitoring: Track GPU, CPU, memory usage
Cost alerts: Notifications when costs exceed thresholds
File cleanup: Automatic cleanup of old temporary files
Monitoring & Alerts
Grafana Dashboard: Real-time metrics visualization
Prometheus Metrics: Custom metrics for 3D pipeline
WebSocket Updates: Real-time progress tracking
Log Aggregation: Centralized logging with Fluentd
Health Checks: Automated service health monitoring
Security Features
Random passwords: Auto-generated secure passwords
Container isolation: Services run in isolated containers
Resource limits: Memory and CPU limits on containers
Network security: Internal Docker networks
Backup & Recovery
Automated backups: Daily backups of output files
Redis persistence: Job queue persistence across restarts
Error recovery: Automatic retry mechanisms
Failed job tracking: Separate queue for failed jobs
Performance Optimizations
CUDA optimization: Tuned for RTX 4090 architecture
Memory management: Efficient memory usage patterns
Queue management: Optimized job distribution
Caching: Intelligent caching of intermediate results
Usage
Upload video: POST to /upload endpoint
Monitor progress: Connect to WebSocket at /ws/{client_id}
Download results: Get .blend file from output directory
View metrics: Access Grafana dashboard
Troubleshooting
GPU not detected: Check nvidia-container-runtime installation
Out of memory: Reduce video resolution or increase system RAM
Queue stuck: Restart workers: docker-compose restart worker_colmap
High costs: Check auto-shutdown settings in .env file
Cost Estimates (Vast.ai)
RTX 4090: ~$0.15-0.25/hour
RTX 3090: ~$0.12-0.18/hour
Processing time: 5-15 minutes per video (depends on length/quality)
Idle cost: ~$0.10/hour (can be auto-shutdown)
Support
Check logs: docker-compose logs -f
Monitor costs: Built-in cost optimizer
Backup data: Automated daily backups
Scale resources: Adjust worker counts in docker-compose.yml