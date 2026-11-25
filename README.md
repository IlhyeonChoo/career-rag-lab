# Career RAG Lab

Week 2 of a cloud architecture course. A Python API checks whether it can read one synthetic job posting. The local run reads a JSON file. In AWS the same handler reads a private S3 object with an ECS task role. The Fargate task calls both routes over loopback, logs their responses, then exits.

## Local run

From the project root, use Python 3.11 and uv.

```bash
uv sync --locked --python 3.11
SAMPLE_FILE=data/sample.json uv run --locked python app.py --smoke-test
```

The successful test prints HTTP 200 for both routes and ends with `SMOKE TEST PASSED`. The local document source is `local-file`.

To inspect the API interactively, leave the server running in one terminal.

```bash
SAMPLE_FILE=data/sample.json uv run --locked python app.py
```

In another terminal, run the following commands.

```bash
curl -i http://127.0.0.1:8080/health
curl -i http://127.0.0.1:8080/sample
```

## Local container test

```bash
docker build --platform linux/amd64 -t career-rag-lab:local .
docker run --rm --network none --read-only --cap-drop ALL \
  -e SAMPLE_FILE=/tmp/sample.json \
  -v "$PWD/data/sample.json:/tmp/sample.json:ro" career-rag-lab:local
```

## Personal AWS account

See [the deployment instructions](infra/README.md) for a one-off task, execution evidence, and cleanup. The AWS run uses an ECR image, one private S3 object, and CloudWatch Logs. Capture the task exit code and the log lines with `HTTP 200`, `"source": "s3"`, and `week2-demo` before cleanup.
