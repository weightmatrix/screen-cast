ARG RUNTIME_IMAGE=python:3.12-slim
FROM ${RUNTIME_IMAGE}
WORKDIR /app
COPY signaling.py /app/signaling.py
COPY audit.py /app/audit.py
COPY Web /app/Web
USER 65534:65534
ENV BIND_HOST=0.0.0.0 TRUST_PROXY=1 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
ENV AUDIT_LOG_PATH=/var/log/touping/connections.jsonl
EXPOSE 8322/tcp 3478/udp
ENTRYPOINT []
CMD ["python", "signaling.py"]
