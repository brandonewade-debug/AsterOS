FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY companion ./companion
USER 99:100
EXPOSE 8790
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8790/health', timeout=2)" || exit 1
CMD ["uvicorn", "companion.api:create_app", "--factory", "--host", "0.0.0.0", "--port", "8790", "--workers", "1", "--no-access-log", "--no-proxy-headers", "--limit-concurrency", "32"]
