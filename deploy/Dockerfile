FROM python:3.13-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements-relay.txt .
RUN pip install --no-cache-dir -r requirements-relay.txt
COPY relay_server.py relay_protocol.py ./
USER 65532:65532
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=3).close()"]
CMD ["uvicorn", "relay_server:app_factory", "--factory", "--host", "0.0.0.0", "--port", "8080", "--no-access-log", "--ws", "websockets", "--ws-max-size", "100000", "--ws-max-queue", "8", "--ws-per-message-deflate", "false"]
