import asyncio
import websockets
import json
import redis.asyncio as redis
import logging
from typing import Set, Dict
import os

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class WebSocketServer:
    def __init__(self):
        self.clients: Dict[str, websockets.WebSocketServerProtocol] = {}
        self.redis_client = redis.Redis.from_url(os.getenv('REDIS_URL', 'redis://redis:6379/0'))
        
    async def register_client(self, websocket: websockets.WebSocketServerProtocol, client_id: str):
        """Register a new WebSocket client"""
        self.clients[client_id] = websocket
        logger.info(f"Client {client_id} connected. Total clients: {len(self.clients)}")
        
        # Send initial status
        await self.send_to_client(client_id, {
            "type": "connection",
            "status": "connected",
            "client_id": client_id
        })
    
    async def unregister_client(self, client_id: str):
        """Unregister a WebSocket client"""
        if client_id in self.clients:
            del self.clients[client_id]
            logger.info(f"Client {client_id} disconnected. Total clients: {len(self.clients)}")
    
    async def send_to_client(self, client_id: str, message: dict):
        """Send message to specific client"""
        if client_id in self.clients:
            try:
                await self.clients[client_id].send(json.dumps(message))
                return True
            except websockets.exceptions.ConnectionClosed:
                await self.unregister_client(client_id)
                return False
            except Exception as e:
                logger.error(f"Error sending to client {client_id}: {e}")
                return False
        return False
    
    async def broadcast(self, message: dict):
        """Broadcast message to all connected clients"""
        if not self.clients:
            return
        
        disconnected_clients = []
        for client_id, websocket in self.clients.items():
            try:
                await websocket.send(json.dumps(message))
            except websockets.exceptions.ConnectionClosed:
                disconnected_clients.append(client_id)
            except Exception as e:
                logger.error(f"Error broadcasting to {client_id}: {e}")
                disconnected_clients.append(client_id)
        
        # Clean up disconnected clients
        for client_id in disconnected_clients:
            await self.unregister_client(client_id)
    
    async def handle_client(self, websocket, path):
        """Handle individual WebSocket client connection"""
        client_id = None
        try:
            # Wait for client identification
            async for message in websocket:
                data = json.loads(message)
                
                if data.get('type') == 'identify':
                    client_id = data.get('client_id', f"client_{id(websocket)}")
                    await self.register_client(websocket, client_id)
                elif data.get('type') == 'subscribe_job':
                    job_id = data.get('job_id')
                    if job_id and client_id:
                        await self.subscribe_to_job_progress(client_id, job_id)
                        
        except websockets.exceptions.ConnectionClosed:
            pass
        except Exception as e:
            logger.error(f"WebSocket error: {e}")
        finally:
            if client_id:
                await self.unregister_client(client_id)
    
    async def subscribe_to_job_progress(self, client_id: str, job_id: str):
        """Subscribe client to job progress updates"""
        try:
            # Get current job status
            job_data = await self.redis_client.get(f"job:{job_id}")
            if job_data:
                await self.send_to_client(client_id, {
                    "type": "job_status",
                    "job_id": job_id,
                    "data": json.loads(job_data)
                })
        except Exception as e:
            logger.error(f"Error subscribing to job {job_id}: {e}")
    
    async def redis_listener(self):
        """Listen for Redis pub/sub messages and forward to WebSocket clients"""
        pubsub = self.redis_client.pubsub()
        await pubsub.psubscribe('progress:*')
        
        logger.info("Started Redis listener for progress updates")
        
        async for message in pubsub.listen():
            if message['type'] == 'pmessage':
                try:
                    channel = message['channel'].decode('utf-8')
                    job_id = channel.split(':', 1)[1]  # Extract job_id from 'progress:job_id'
                    data = json.loads(message['data'])
                    
                    # Broadcast to all clients (you could filter by job_id if needed)
                    await self.broadcast({
                        "type": "progress_update",
                        "job_id": job_id,
                        "data": data
                    })
                    
                except Exception as e:
                    logger.error(f"Error processing Redis message: {e}")

# HTTP endpoints for direct progress updates
from aiohttp import web, web_runner
import asyncio

async def progress_endpoint(request):
    """HTTP endpoint for progress updates"""
    try:
        data = await request.json()
        job_id = data.get('job_id')
        
        if job_id:
            # Store in Redis and broadcast
            await server.redis_client.publish(f"progress:{job_id}", json.dumps(data))
            
            return web.json_response({"status": "success"})
        else:
            return web.json_response({"error": "job_id required"}, status=400)
            
    except Exception as e:
        logger.error(f"Progress endpoint error: {e}")
        return web.json_response({"error": str(e)}, status=500)

async def metrics_endpoint(request):
    """HTTP endpoint for system metrics"""
    try:
        data = await request.json()
        
        # Broadcast metrics to all clients
        await server.broadcast({
            "type": "system_metrics",
            "data": data
        })
        
        return web.json_response({"status": "success"})
        
    except Exception as e:
        logger.error(f"Metrics endpoint error: {e}")
        return web.json_response({"error": str(e)}, status=500)

# Global server instance
server = WebSocketServer()

async def main():
    """Main server function"""
    # Start WebSocket server
    websocket_server = websockets.serve(
        server.handle_client, 
        "0.0.0.0", 
        8765,
        ping_interval=30,
        ping_timeout=10
    )
    
    # Start HTTP server for direct updates
    app = web.Application()
    app.router.add_post('/progress', progress_endpoint)
    app.router.add_post('/metrics', metrics_endpoint)
    
    runner = web_runner.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, '0.0.0.0', 8766)
    await site.start()
    
    logger.info("WebSocket server started on :8765")
    logger.info("HTTP server started on :8766")
    
    # Start Redis listener
    redis_task = asyncio.create_task(server.redis_listener())
    websocket_task = asyncio.create_task(websocket_server)
    
    # Run both tasks concurrently
    await asyncio.gather(redis_task, websocket_task)

if __name__ == "__main__":
    asyncio.run(main())