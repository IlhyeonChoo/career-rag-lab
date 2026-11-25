FROM ghcr.io/astral-sh/uv:0.8.22 AS uv
FROM python:3.11-slim
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /app
ENV PYTHONUNBUFFERED=1
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
ENV PATH="/app/.venv/bin:${PATH}"
COPY app.py ./
USER 65534:65534
CMD ["python", "app.py", "--smoke-test"]
