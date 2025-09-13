# Use a slim Python base image
FROM python:3.10-slim

# Set working directory
WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY server.py .

# Expose the port the app runs on
EXPOSE 8765
EXPOSE 8766

# Run the application
CMD ["python", "server.py"]