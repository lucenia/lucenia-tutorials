"""Tiny OpenAI-compatible embeddings server for Lucenia agent memory.

Why this exists: Lucenia's memory module (plugins.memory.embedding.provider=http)
sends text to an OpenAI-style embeddings endpoint and stores the returned vectors
for semantic recall. This server answers that call locally with
all-MiniLM-L6-v2 (ONNX, CPU, 384 dimensions), so no API key or cloud account is
needed.

  POST /v1/embeddings  {"input": "text" | ["text", ...], "model": "..."}
       -> {"object": "list", "data": [{"object": "embedding", "index": 0,
           "embedding": [384 floats]}], "model": "...", "usage": {...}}
  GET  /health         -> {"status": "ok", "model": "...", "dimension": 384}

Notes
  * Input is truncated to 256 word-pieces (the model's training limit), roughly
    150-200 English words. Keep memories short, one fact each.
  * Vectors are mean-pooled and L2-normalised, like the sentence-transformers
    reference implementation.
  * MODEL_NAME only changes the label returned in responses; the weights are the
    files in MODEL_DIR.
  * Request hygiene: POST needs a Content-Length that is a non-negative integer
    (400 otherwise; chunked uploads are not accepted), bodies above MAX_BODY get
    413, and both are refused BEFORE any body is read. Every socket read or write
    gives up after SOCKET_TIMEOUT seconds, so a client that stalls cannot hold a
    thread (the timeout is per read, not a deadline for the whole request).
"""
import json
import os
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

MODEL_DIR = os.environ.get("MODEL_DIR", "/models")
MODEL_NAME = os.environ.get("MODEL_NAME", "all-MiniLM-L6-v2")
PORT = int(os.environ.get("PORT", "8080"))
MAX_LEN = 256                 # sentence_bert_config.json: max_seq_length
MAX_BATCH = 128               # texts per request
MAX_BODY = 8 * 1024 * 1024    # bytes per request
SOCKET_TIMEOUT = 30           # seconds a single socket read/write may block (also closes idle keep-alive connections)

tok = Tokenizer.from_file(f"{MODEL_DIR}/tokenizer.json")
tok.enable_truncation(max_length=MAX_LEN)
tok.enable_padding(pad_id=0, pad_token="[PAD]")
opts = ort.SessionOptions()
opts.intra_op_num_threads = int(os.environ.get("ORT_THREADS", "2"))
sess = ort.InferenceSession(f"{MODEL_DIR}/model.onnx", opts, providers=["CPUExecutionProvider"])
INPUTS = {i.name for i in sess.get_inputs()}


def embed(texts):
    """Return (vectors [n, dim], token_count)."""
    enc = tok.encode_batch(texts)
    ids = np.array([e.ids for e in enc], dtype=np.int64)
    mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
    feed = {"input_ids": ids, "attention_mask": mask}
    if "token_type_ids" in INPUTS:
        feed["token_type_ids"] = np.zeros_like(ids)
    hidden = sess.run(None, feed)[0]                                # [batch, seq, dim]
    m = mask[..., None].astype(np.float32)
    pooled = (hidden * m).sum(1) / np.clip(m.sum(1), 1e-9, None)    # mean pooling
    pooled /= np.clip(np.linalg.norm(pooled, axis=1, keepdims=True), 1e-12, None)  # L2 normalise
    return pooled, int(mask.sum())


# Load-time warm-up: the first ONNX run is slow; do it before we accept traffic
# so the healthcheck only passes once the model is really ready.
DIM = embed(["warm-up"])[0].shape[1]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"          # keep-alive, so Lucenia can reuse connections
    server_version = "embed-server"
    timeout = SOCKET_TIMEOUT               # StreamRequestHandler applies this to the connection socket

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code, message):
        self._send(code, {"error": {"message": message, "type": "invalid_request_error"}})

    def _refuse(self, code, message):
        """Answer without having read the body: the connection must close, or the unread body would be
        parsed as the next request."""
        self.close_connection = True
        self._error(code, message)

    def log_message(self, fmt, *args):
        # A malformed request line ("GARBAGE") never sets self.path, and logging that error must not raise.
        if getattr(self, "path", "") in ("/health", "/"):   # keep the docker healthcheck out of the logs
            return
        super().log_message(fmt, *args)

    def do_GET(self):
        if self.path in ("/health", "/"):
            return self._send(200, {"status": "ok", "model": MODEL_NAME, "dimension": DIM})
        self._error(404, "not found")

    def do_POST(self):
        if self.path.rstrip("/") not in ("/v1/embeddings", "/embeddings"):
            return self._refuse(404, "not found")
        # Validate Content-Length before reading anything. A missing, empty, signed ("-1"), fractional or
        # non-ASCII value is refused: int() would accept "-1" and rfile.read(-1) reads until the client hangs up.
        raw_length = self.headers.get("Content-Length")
        if raw_length is None or not (raw_length.isascii() and raw_length.isdigit()):
            return self._refuse(400, "Content-Length must be a non-negative integer")
        length = int(raw_length)
        if length > MAX_BODY:
            return self._refuse(413, f"request body larger than {MAX_BODY} bytes")
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(req, dict):
                return self._error(400, "the request body must be a JSON object")
            inp = req.get("input", [])
            texts = [inp] if isinstance(inp, str) else list(inp)
            if len(texts) > MAX_BATCH:
                return self._error(400, f"at most {MAX_BATCH} inputs per request")
            if not all(isinstance(t, str) for t in texts):
                return self._error(400, "input must be a string or a list of strings")
            t0 = time.perf_counter()
            vecs, n_tokens = embed(texts) if texts else (np.zeros((0, DIM), dtype=np.float32), 0)
            self.log_message("embedded %d text(s), %d tokens, %.1f ms",
                             len(texts), n_tokens, (time.perf_counter() - t0) * 1000)
            self._send(200, {
                "object": "list",
                "model": req.get("model") or MODEL_NAME,
                "data": [{"object": "embedding", "index": i, "embedding": v.tolist()}
                         for i, v in enumerate(vecs)],
                "usage": {"prompt_tokens": n_tokens, "total_tokens": n_tokens},
            })
        except (TimeoutError, ConnectionError):         # the client stalled or went away: nobody to answer
            self.close_connection = True
        except (ValueError, TypeError) as e:           # bad JSON, bad types
            self._error(400, str(e))
        except Exception as e:  # noqa: BLE001
            self._error(500, f"embedding failed: {e}")


def _stop(signum, frame):  # docker stop sends SIGTERM; PID 1 ignores it unless handled
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _stop)
    print(f"embed-server: model={MODEL_NAME} dim={DIM} listening on :{PORT}", flush=True)
    try:
        ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        pass
