import bpy
import sys
import os
import json
import time
import logging
import traceback
import subprocess
from pathlib import Path
import redis
import requests

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/app/logs/blender_worker.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# Redis connection
redis_client = redis.Redis.from_url(os.getenv('REDIS_URL', 'redis://redis:6379/0'))

def report_progress(job_id, stage, progress, message):
    """Report progress via WebSocket and Redis"""
    try:
        payload = {
            "job_id": job_id,
            "stage": stage,
            "progress": progress,
            "message": message,
            "timestamp": time.time()
        }
        
        # Send to WebSocket server
        websocket_url = os.getenv('WEBSOCKET_URL', 'ws://websocket:8765')
        if websocket_url.startswith('ws://'):
            websocket_url = websocket_url.replace('ws://', 'http://') + '/progress'
        
        requests.post(websocket_url, json=payload, timeout=5)
        
        # Publish to Redis
        redis_client.publish(f"progress:{job_id}", json.dumps(payload))
        
    except Exception as e:
        logger.error(f"Failed to report progress: {e}")

def install_colmap_addon():
    """Install and enable COLMAP import addon"""
    try:
        # Check if addon is already enabled
        if 'photogrammetry_importer' in bpy.context.preferences.addons:
            logger.info("COLMAP addon already enabled")
            return True
        
        # Try to install from various sources
        addon_paths = [
            '/app/addons/photogrammetry_importer.zip',
            '/opt/blender_addons/photogrammetry_importer.zip'
        ]
        
        for addon_path in addon_paths:
            if os.path.exists(addon_path):
                try:
                    bpy.ops.preferences.addon_install(filepath=addon_path, overwrite=True)
                    bpy.ops.preferences.addon_enable(module='photogrammetry_importer')
                    logger.info(f"Installed COLMAP addon from {addon_path}")
                    return True
                except Exception as e:
                    logger.warning(f"Failed to install addon from {addon_path}: {e}")
        
        # Try to enable if already installed
        try:
            bpy.ops.preferences.addon_enable(module='photogrammetry_importer')
            logger.info("Enabled existing COLMAP addon")
            return True
        except:
            pass
        
        logger.error("Could not install or enable COLMAP addon")
        return False
        
    except Exception as e:
        logger.error(f"Addon installation failed: {e}")
        return False

def import_colmap_scene(scene_path, job_id):
    """Import COLMAP scene with error handling"""
    try:
        # Reset Blender scene
        bpy.ops.wm.read_factory_settings(use_empty=True)
        
        # Install addon
        if not install_colmap_addon():
            raise Exception("Failed to install COLMAP addon")
        
        report_progress(job_id, "blender_import", 10, "Preparing Blender scene")
        
        # Check for sparse reconstruction
        sparse_path = Path(scene_path) / "sparse" / "0"
        if not sparse_path.exists():
            raise Exception(f"No sparse reconstruction found in {sparse_path}")
        
        required_files = ["cameras.bin", "images.bin", "points3D.bin"]
        for req_file in required_files:
            if not (sparse_path / req_file).exists():
                raise Exception(f"Missing required file: {req_file}")
        
        report_progress(job_id, "blender_import", 30, "Loading COLMAP data")
        
        # Import COLMAP data
        try:
            bpy.ops.import_scene.colmap(
                colmap_sparse_folder_path=str(sparse_path),
                colmap_image_folder_path=str(Path(scene_path).parent / "temp_images"),
                suppress_distortion_warnings=True,
                add_camera_motion_as_animation=True,
                add_points_as_point_cloud=True,
                add_cameras=True
            )
        except Exception as e:
            logger.warning(f"Standard COLMAP import failed: {e}")
            # Try alternative import method
            try:
                bpy.ops.import_scene.photogrammetry_models(
                    filepath=str(sparse_path / "cameras.bin"),
                    import_cameras=True,
                    import_points=True
                )
            except Exception as e2:
                raise Exception(f"All import methods failed: {e}, {e2}")
        
        report_progress(job_id, "blender_import", 60, "Optimizing scene")
        
        # Scene optimization
        optimize_scene()
        
        report_progress(job_id, "blender_import", 80, "Setting up materials and lighting")
        
        # Setup basic materials and lighting
        setup_scene_materials()
        
        return True
        
    except Exception as e:
        logger.error(f"COLMAP import failed: {e}")
        logger.error(traceback.format_exc())
        return False

def optimize_scene():
    """Optimize the imported scene for better performance"""
    try:
        # Limit point cloud density if too many points
        point_clouds = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH' and 'point' in obj.name.lower()]
        
        for pc in point_clouds:
            if len(pc.data.vertices) > 100000:  # If more than 100k points
                # Add decimation modifier
                dec_mod = pc.modifiers.new(name="Decimate", type='DECIMATE')
                dec_mod.ratio = 0.5  # Reduce by half
                logger.info(f"Added decimation to {pc.name}")
        
        # Setup efficient viewport shading
        for area in bpy.context.screen.areas:
            if area.type == 'VIEW_3D':
                area.spaces[0].shading.type = 'SOLID'
                break
                
    except Exception as e:
        logger.warning(f"Scene optimization failed: {e}")

def setup_scene_materials():
    """Setup basic materials and lighting"""
    try:
        # Add basic lighting
        if not any(obj.type == 'LIGHT' for obj in bpy.context.scene.objects):
            bpy.ops.object.light_add(type='SUN', location=(10, 10, 10))
            sun = bpy.context.active_object
            sun.data.energy = 3
        
        # Setup basic material for cameras
        camera_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'CAMERA']
        if camera_objects and len(camera_objects) > 1:  # Multiple cameras from COLMAP
            # Create camera path animation
            setup_camera_animation(camera_objects)
            
    except Exception as e:
        logger.warning(f"Material setup failed: {e}")

def setup_camera_animation(cameras):
    """Create smooth camera animation from COLMAP cameras"""
    try:
        if len(cameras) < 2:
            return
        
        # Create camera animation curve
        scene = bpy.context.scene
        scene.frame_start = 1
        scene.frame_end = len(cameras) * 5  # 5 frames per camera position
        
        # Animate primary camera through all positions
        main_camera = cameras[0]
        main_camera.name = "AnimatedCamera"
        
        for i, cam in enumerate(cameras[1:], 1):
            frame = i * 5
            
            # Copy location and rotation
            main_camera.location = cam.location.copy()
            main_camera.rotation_euler = cam.rotation_euler.copy()
            
            # Insert keyframes
            main_camera.keyframe_insert(data_path="location", frame=frame)
            main_camera.keyframe_insert(data_path="rotation_euler", frame=frame)
        
        # Set interpolation to bezier for smooth animation
        if main_camera.animation_data and main_camera.animation_data.action:
            for fcurve in main_camera.animation_data.action.fcurves:
                for keyframe in fcurve.keyframe_points:
                    keyframe.interpolation = 'BEZIER'
                    keyframe.handle_left_type = 'AUTO'
                    keyframe.handle_right_type = 'AUTO'
        
        logger.info(f"Created camera animation with {len(cameras)} keyframes")
        
    except Exception as e:
        logger.warning(f"Camera animation setup failed: {e}")

def process_blender_job(job_data):
    """Process a single Blender job"""
    job_id = job_data.get('job_id')
    scene_path = job_data.get('scene_path')
    output_path = job_data.get('output_path')
    
    logger.info(f"Processing Blender job {job_id}")
    
    try:
        # Update job status
        job_data['status'] = 'processing_blender'
        job_data['blender_started_at'] = time.time()
        redis_client.set(f"job:{job_id}", json.dumps(job_data))
        
        # Validate paths
        if not os.path.exists(scene_path):
            raise Exception(f"Scene path does not exist: {scene_path}")
        
        # Create output directory
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        
        # Import COLMAP scene
        if not import_colmap_scene(scene_path, job_id):
            raise Exception("Failed to import COLMAP scene")
        
        report_progress(job_id, "blender_save", 90, "Saving Blender file")
        
        # Save blend file
        bpy.ops.wm.save_as_mainfile(filepath=output_path)
        
        # Verify file was saved
        if not os.path.exists(output_path):
            raise Exception("Failed to save blend file")
        
        file_size = os.path.getsize(output_path)
        logger.info(f"Saved blend file: {output_path} ({file_size} bytes)")
        
        # Update job status
        job_data['status'] = 'completed'
        job_data['completed_at'] = time.time()
        job_data['output_file'] = output_path
        job_data['file_size'] = file_size
        redis_client.set(f"job:{job_id}", json.dumps(job_data))
        
        report_progress(job_id, "completed", 100, f"Processing completed. File saved: {os.path.basename(output_path)}")
        
        return True
        
    except Exception as e:
        logger.error(f"Blender job {job_id} failed: {e}")
        logger.error(traceback.format_exc())
        
        # Update job status
        job_data['status'] = 'failed_blender'
        job_data['error'] = str(e)
        job_data['failed_at'] = time.time()
        redis_client.set(f"job:{job_id}", json.dumps(job_data))
        
        report_progress(job_id, "failed", 0, f"Blender processing failed: {str(e)}")
        
        return False

def main_worker_loop():
    """Main Blender worker loop"""
    logger.info("Starting Enhanced Blender Worker")
    
    max_retries = int(os.getenv('MAX_RETRIES', '3'))
    retry_delay = 30
    
    while True:
        try:
            # Get job from queue
            job_result = redis_client.brpop(['blender_jobs'], timeout=60)
            
            if not job_result:
                continue
            
            _, job_data_str = job_result
            job_data = json.loads(job_data_str)
            
            job_id = job_data.get('job_id')
            retries = job_data.get('blender_retries', 0)
            
            logger.info(f"Processing Blender job {job_id} (attempt {retries + 1})")
            
            # Process job
            if process_blender_job(job_data):
                logger.info(f"Blender job {job_id} completed successfully")
            else:
                # Handle retry logic
                if retries < max_retries:
                    new_retries = retries + 1
                    logger.info(f"Blender job {job_id} failed, retrying ({new_retries}/{max_retries})")
                    
                    job_data['blender_retries'] = new_retries
                    job_data['status'] = 'retry_blender'
                    
                    # Re-queue with delay
                    time.sleep(retry_delay)
                    redis_client.lpush('blender_jobs', json.dumps(job_data))
                else:
                    logger.error(f"Blender job {job_id} failed after {max_retries} attempts")
                    redis_client.lpush('failed_blender_jobs', json.dumps(job_data))
            
        except KeyboardInterrupt:
            logger.info("Worker interrupted, shutting down...")
            break
        except Exception as e:
            logger.error(f"Worker loop error: {e}")
            logger.error(traceback.format_exc())
            time.sleep(10)  # Brief pause before continuing

if __name__ == "__main__":
    main_worker_loop()