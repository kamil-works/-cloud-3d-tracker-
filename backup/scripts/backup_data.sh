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