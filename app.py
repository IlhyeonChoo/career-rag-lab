"""Verify the private API and read the week 2 sample document."""

import argparse
from contextlib import closing
from functools import lru_cache
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import sys
from threading import Thread


SAMPLE_KEY = "week2/sample.json"


@lru_cache(maxsize=1)
def s3_client():
    import boto3
    from botocore.config import Config

    config = Config(
        retries={"mode": "standard", "total_max_attempts": 2},
        connect_timeout=3,
        read_timeout=5,
    )
    return boto3.client("s3", config=config)


def read_sample() -> dict:
    """Read the fixture from the single configured storage backend."""
    file = os.environ.get("SAMPLE_FILE")
    bucket = os.environ.get("SAMPLE_BUCKET")
    if bool(file) == bool(bucket):
        raise ValueError("Configure exactly one of SAMPLE_FILE or SAMPLE_BUCKET.")
    if file:
        source = "local-file"
        raw = Path(file).read_bytes()
    else:
        from botocore.exceptions import BotoCoreError, ClientError

        source = "s3"
        try:
            result = s3_client().get_object(Bucket=bucket, Key=SAMPLE_KEY)
            with closing(result["Body"]) as stream:
                raw = stream.read()
        except (BotoCoreError, ClientError) as exc:
            raise OSError("S3 GetObject failed.") from exc
    sample = json.loads(raw)
    if not isinstance(sample, dict) or not sample.get("document_id"):
        raise ValueError("The sample must contain a document_id.")
    return {"source": source, "sample": sample}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/health":
            status, body = 200, {"status": "ok"}
        elif self.path == "/sample":
            try:
                status, body = 200, read_sample()
            except (OSError, ValueError) as exc:
                print(f"Sample read failed ({type(exc).__name__}).", file=sys.stderr)
                status, body = 503, {"error": "sample unavailable"}
        else:
            status, body = 404, {"error": "not found"}
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def smoke_test(server: HTTPServer) -> bool:
    """Make real HTTP requests to the loopback API and validate both replies."""
    worker = Thread(target=server.serve_forever, daemon=True)
    worker.start()
    expected_source = "s3" if os.environ.get("SAMPLE_BUCKET") else "local-file"
    try:
        for path in ("/health", "/sample"):
            with closing(HTTPConnection("127.0.0.1", server.server_port, timeout=30)) as client:
                client.request("GET", path)
                response = client.getresponse()
                payload = json.load(response)
            print(f"GET {path} HTTP {response.status}  {json.dumps(payload, ensure_ascii=False)}")
            if response.status != 200:
                return False
            if path == "/health" and payload.get("status") != "ok":
                return False
            if path == "/sample" and (
                payload.get("source") != expected_source
                or payload.get("sample", {}).get("document_id") != "week2-demo"
            ):
                return False
        print("SMOKE TEST PASSED")
        return True
    finally:
        server.shutdown()
        worker.join()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smoke-test", action="store_true")
    args = parser.parse_args()
    port = int(os.getenv("PORT", "8080"))
    with HTTPServer(("127.0.0.1", port), Handler) as server:
        if args.smoke_test:
            return 0 if smoke_test(server) else 1
        print(f"Listening on http://127.0.0.1:{server.server_port}", flush=True)
        server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
