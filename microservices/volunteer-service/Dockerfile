FROM python:3.12-slim AS builder

WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt


FROM python:3.12-slim

RUN groupadd -g 10001 app \
    && useradd -u 10001 -g app -s /sbin/nologin -m -d /home/app app

COPY --from=builder /opt/venv /opt/venv

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8083

WORKDIR /app
COPY --chown=app:app app.py ./

USER app
EXPOSE 8083

CMD ["gunicorn", "--bind", "0.0.0.0:8083", "--workers", "2", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
