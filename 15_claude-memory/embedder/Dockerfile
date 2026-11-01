# Embedding sidecar for Lucenia agent memory (tutorial 15).
#
# Lucenia's memory module needs an embedding provider. The only provider that
# gives real semantic recall without cloud credentials is "http": Lucenia POSTs
# text to an OpenAI-style /v1/embeddings endpoint. This image is that endpoint,
# serving all-MiniLM-L6-v2 (384 dimensions, Apache-2.0) on the CPU via ONNX
# Runtime. It runs on arm64 and amd64 (no architecture-specific pins).
#
# The build downloads ~90 MB of model files from Hugging Face ONCE. The files
# are pinned to an exact repository commit and verified with SHA-256, so a
# changed or truncated download fails the build instead of silently producing
# different vectors.

FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN pip install --no-cache-dir onnxruntime==1.22.0 tokenizers==0.21.1 numpy==2.2.6

# sentence-transformers/all-MiniLM-L6-v2 @ 1110a243fdf4 (public, no login)
ADD https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/1110a243fdf4706b3f48f1d95db1a4f5529b4d41/onnx/model.onnx /models/model.onnx
ADD https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/1110a243fdf4706b3f48f1d95db1a4f5529b4d41/tokenizer.json /models/tokenizer.json

# ADD from a URL creates root-only files; verify the download, then make it readable.
RUN printf '%s\n' \
      '6fd5d72fe4589f189f8ebc006442dbb529bb7ce38f8082112682524616046452  /models/model.onnx' \
      'be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037  /models/tokenizer.json' \
      | sha256sum -c - \
 && chmod 644 /models/model.onnx /models/tokenizer.json

COPY embed_server.py /app/embed_server.py

# Run as "nobody"; the server only needs to read the model files.
USER 65534:65534
EXPOSE 8080
CMD ["python", "/app/embed_server.py"]
