FROM python:3.11-slim
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

RUN useradd -m appuser
COPY --chown=appuser:appuser . .
USER appuser

HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8002/health')"

EXPOSE 8002
CMD ["gunicorn", "--bind", "0.0.0.0:8002", "app:app"]
