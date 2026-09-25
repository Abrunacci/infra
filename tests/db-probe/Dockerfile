# Test image for per-project databases (see README.md). Built by
# .github/workflows/db-probe.yml with PROBE_VERSION set to v1, v2 or v3.
FROM python:3.13.15-slim-trixie@sha256:8d9d0b8bcf6506481eae4907c18f5e3e7902e629f5f6d684f9e7c32e85e3ddf0

ARG PROBE_VERSION
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PROBE_VERSION=${PROBE_VERSION}

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --no-compile --require-hashes -r requirements.txt

COPY app.py migrate.py ./
# Only the migrations this version has: v1 001, v2 up to 002, v3 up to 003.
COPY migrations/ /tmp/migrations/
RUN mkdir migrations \
    && case "$PROBE_VERSION" in \
         v1) keep=1 ;; v2) keep=2 ;; v3) keep=3 ;; \
         *) echo "PROBE_VERSION must be v1, v2 or v3" >&2; exit 1 ;; \
       esac \
    && ls /tmp/migrations/*.sql | sort | head -n "$keep" | xargs -I{} cp {} migrations/ \
    && rm -rf /tmp/migrations \
    && chmod -R a+rX /app

# The server runs it as its own non-root user whatever this says; readable
# files are all it needs.
USER 65534
EXPOSE 8080
CMD ["python", "app.py"]
