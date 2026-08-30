# Forex MT5 Copy Sync
FROM python:3.11-slim

# Non-root by default: the app only needs to write ./data.
RUN useradd --create-home --shell /usr/sbin/nologin appuser
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN mkdir -p /app/data && chown -R appuser:appuser /app
USER appuser

# Bind to all interfaces INSIDE the container; publish it only to a
# reverse proxy on the host (see deploy/nginx.conf.example).
ENV FOREX_MT5_COPY_HOST=0.0.0.0     FOREX_MT5_COPY_PORT=18197

EXPOSE 18197
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s   CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:18197/api/health',timeout=3).status==200 else 1)"

CMD ["python", "app.py"]
