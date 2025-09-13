
### `backend/` Directory

#### `backend/api/app_prod.py`
```python
from fastapi import FastAPI, UploadFile, File, WebSocket, HTTPException, BackgroundTasks
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import os, uuid, shutil, asyncio, json, time
from typing import Dict, List
import redis.asyncio as redis
import websockets
import sentry_sdk
from sentry_sdk.integrations.fastapi import FastApiIntegration
from prometheus_client import Counter, Histogram, Gauge, start_http_server
import logging
from contextlib import asynccontextmanager

# Metrics
REQUEST_COUNT = Counter('api_requests_total', 'Total API requests', ['method', 'endpoint'])
REQUEST_DURATION = Histogram('api_request_duration_seconds', 'Request duration')
ACTIVE_JOBS = Gauge('active_jobs_total', 'Number of active processing jobs')
QUEUE_SIZE = Gauge('queue_size_total', 'Size of job queue')

# Initialize Sentry
sentry_sdk.init(
    dsn=os.getenv('SENTRY_DSN'),
    integrations=[FastApiIntegration()],
    traces_sample_rate=1.0,
)

# Enhanced logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/app/logs/api.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    start_http_server(8001)  # Prometheus metrics
    yield
    # Shutdown cleanup

app = FastAPI(
    title="3D Tracker API",
    description="Production-ready 3D reconstruction pipeline",
    version="2.0.0",
    lifespan=lifespan
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Redis connection
redis_client = redis.Redis.from_url(os.getenv('REDIS_URL', 'redis://redis:6379/0'))

# WebSocket connections manager
class ConnectionManager:
    def __init__(self):
        self.active_connections: Dict[str, WebSocket] = {}

    async def connect(self, websocket: WebSocket, client_id: str):
        await websocket.accept()
        self.active_connections[client_id] = websocket
        logger.info(f"Client {client_id} connected")

    def disconnect(self, client_id: str):
        if client_id in self.active_connections:
            del self.active_connections[client_id]
            logger.info(f"Client {client_id} disconnected")

    async def send_progress(self, client_id: str, progress: dict):
        if client_id in self.active_connections:
            try:
                await self.active_connections[client_id].send_text(json.dumps(progress))
            except Exception as e:
                logger.error(f"Failed to send progress to {client_id}: {e}")
                self.disconnect(client_id)

manager = ConnectionManager()

# Enhanced upload endpoint with validation and monitoring
@app.post('/upload')
async def upload_video(file: UploadFile = File(...)):
    REQUEST_COUNT.labels(method='POST', endpoint='/upload').inc()
    start_time = time.time()
    
    try:
        # Validation
        if not file.filename.lower().endswith(('.mp4', '.mov', '.avi', '.mkv')):
            raise HTTPException(status_code=400, detail="Invalid file format")
        
        if file.size > int(os.getenv('MAX_UPLOAD_SIZE', '2147483648')):  # 2GB
            raise HTTPException(status_code=400, detail="File too large")
        
        # Generate unique job ID
        job_id = str(uuid.uuid4())
        filename = f"{job_id}_{file.filename}"
        filepath = os.path.join('/app/input_videos', filename)
        
        # Save file with progress tracking
        with open(filepath, 'wb') as f:
            shutil.copyfileobj(file.file, f)
        
        # Enqueue job with retry mechanism
        job_data = {
            'job_id': job_id,
            'filename': filename,
            'filepath': filepath,
            'status': 'queued',
            'created_at': time.time(),
            'retries': 0,
            'max_retries': 3
        }
        
        await redis_client.lpush('colmap_jobs', json.dumps(job_data))
        await redis_client.set(f"job:{job_id}", json.dumps(job_data))
        
        ACTIVE_JOBS.inc()
        QUEUE_SIZE.set(await redis_client.llen('colmap_jobs'))
        
        logger.info(f"Job {job_id} queued successfully")
        
        return JSONResponse({
            'status': 'success',
            'job_id': job_id,
            'message': 'File uploaded and queued for processing'
        })
        
    except Exception as e:
        logger.error(f"Upload failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    
    finally:
        REQUEST_DURATION.observe(time.time() - start_time)

# Job status endpoint
@app.get('/job/{job_id}/status')
async def get_job_status(job_id: str):
    try:
        job_data = await redis_client.get(f"job:{job_id}")
        if not job_data:
            raise HTTPException(status_code=404, detail="Job not found")
        
        return JSONResponse(json.loads(job_data))
    
    except Exception as e:
        logger.error(f"Status check failed for {job_id}: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# WebSocket endpoint for real-time progress
@app.websocket("/ws/{client_id}")
async def websocket_endpoint(websocket: WebSocket, client_id: str):
    await manager.connect(websocket, client_id)
    try:
        while True:
            await websocket.receive_text()
    except Exception as e:
        logger.error(f"WebSocket error for {client_id}: {e}")
    finally:
        manager.disconnect(client_id)

# Health check with detailed status
@app.get('/health')
async def health_check():
    try:
        # Check Redis connection
        await redis_client.ping()
        redis_status = "healthy"
    except:
        redis_status = "unhealthy"
    
    return {
        'status': 'healthy',
        'timestamp': time.time(),
        'services': {
            'redis': redis_status,
            'gpu': 'available' if os.path.exists('/dev/nvidia0') else 'unavailable'
        },
        'metrics': {
            'active_jobs': ACTIVE_JOBS._value.get(),
            'queue_size': QUEUE_SIZE._value.get()
        }
    }

# Metrics endpoint
@app.get('/metrics')
async def get_metrics():
    return {
        'active_jobs': ACTIVE_JOBS._value.get(),
        'queue_size': QUEUE_SIZE._value.get(),
        'total_requests': REQUEST_COUNT._value.sum()
    }