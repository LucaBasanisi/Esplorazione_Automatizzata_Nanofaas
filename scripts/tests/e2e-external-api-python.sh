#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

FN_NAME="api-python"
FN_DIR="$PROJECT_DIR/examples/python/$FN_NAME"

log "Configurazione $FN_NAME..."
rm -rf "$FN_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$FN_NAME" --lang python --out "$PROJECT_DIR/examples/python" --yes

cat <<EOF > "$FN_DIR/handler.py"
import requests
from nanofaas.sdk import nanofaas_function

@nanofaas_function
def handle(req):
    try:
        response = requests.get('$API_URL')
        return response.json()
    except Exception as e:
        return {"error": str(e)}
EOF

# Calcola il percorso relativo per il Dockerfile
REL_FN_DIR=${FN_DIR#$PROJECT_DIR/}

cat <<EOF > "$FN_DIR/Dockerfile"
FROM $BASE_IMAGE AS builder
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG $PIP_PKG $CURL_PKG
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uv/bin/
COPY sdks/python/ /tmp/sdk/
RUN /uv/bin/uv pip install --system --target /deps /tmp/sdk/ requests==2.32.3

FROM $BASE_IMAGE
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG
WORKDIR /app
COPY --from=builder /deps $PYTHON_SITE_PATH
COPY $REL_FN_DIR/ /app/
ENV HANDLER_MODULE=handler PORT=8080 PYTHONPATH=/app
EXPOSE 8080
CMD ["python3", "-m", "uvicorn", "nanofaas.runtime.app:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

deploy_and_test "$FN_NAME" "$FN_DIR"
