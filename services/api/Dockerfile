FROM python:3.12-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1
WORKDIR /build

COPY pyproject.toml README.md ./
COPY src ./src
COPY alembic.ini ./
COPY alembic ./alembic
RUN python -m pip wheel --wheel-dir /wheels .

FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    FINGERSPEAK_WEBSOCKET_MAX_MESSAGE_BYTES=4096
WORKDIR /app

RUN addgroup --system fingerspeak && adduser --system --ingroup fingerspeak fingerspeak
COPY --from=builder /wheels /wheels
RUN python -m pip install /wheels/* && rm -rf /wheels
COPY --from=builder /build/alembic.ini ./alembic.ini
COPY --from=builder /build/alembic ./alembic

USER fingerspeak
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health/ready', timeout=2)"

CMD ["sh", "-c", "exec uvicorn fingerspeak_api.main:app --host 0.0.0.0 --port 8000 --ws-max-size \"${FINGERSPEAK_WEBSOCKET_MAX_MESSAGE_BYTES}\""]
