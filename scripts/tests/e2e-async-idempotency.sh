#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

log "======================================================"
log "Setup E2E Idempotency Test (Python)..."
log "======================================================"

CP_IP=$(run_vm "sudo kubectl get svc -n nanofaas control-plane -o jsonpath='{.spec.clusterIP}'")
log "Control Plane IP: $CP_IP"

FUNC_NAME="idem-test-python"
FUNC_DIR="$PROJECT_DIR/examples/python/$FUNC_NAME"

log "Inizializzazione funzione $FUNC_NAME..."
rm -rf "$FUNC_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$FUNC_NAME" --lang python --out "$PROJECT_DIR/examples/python" --yes

cat <<EOF > "$FUNC_DIR/handler.py"
import time
from nanofaas.sdk import nanofaas_function

@nanofaas_function
def handle(req):
    print("--- IDEM TEST ACTIVE ---", flush=True)
    time.sleep(2)
    return {"status": "idem_done", "message": "hello idempotency!"}
EOF

REL_FUNC_DIR=${FUNC_DIR#$PROJECT_DIR/}
cat <<EOF > "$FUNC_DIR/Dockerfile"
FROM $BASE_IMAGE AS builder
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG $PIP_PKG
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uv/bin/
COPY sdks/python/ /tmp/sdk/
RUN /uv/bin/uv pip install --system --target /deps /tmp/sdk/ requests

FROM $BASE_IMAGE
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG
WORKDIR /app
COPY --from=builder /deps $PYTHON_SITE_PATH
COPY $REL_FUNC_DIR/ /app/
ENV HANDLER_MODULE=handler PORT=8080 PYTHONPATH=/app
EXPOSE 8080
CMD ["python3", "-m", "uvicorn", "nanofaas.runtime.app:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

log "Building and pushing $FUNC_NAME..."
run_vm "cd ~/nanofaas && sudo docker build -t $REGISTRY/nanofaas/$FUNC_NAME:latest -f $REL_FUNC_DIR/Dockerfile ."
run_vm "sudo docker push $REGISTRY/nanofaas/$FUNC_NAME:latest"

sed -i "s|image: .*|image: $REGISTRY/nanofaas/$FUNC_NAME:latest|" "$FUNC_DIR/function.yaml"
run_vm "nanofaas fn apply -f /home/ubuntu/nanofaas/$REL_FUNC_DIR/function.yaml"

log "Attesa avvio pod..."
wait_for_pod_ready "$FUNC_NAME"

IDEM_KEY="test-idempotency-key-123"

log "======================================================"
log "Prima Invocazione Asincrona (IDEM_KEY=$IDEM_KEY)..."
log "======================================================"
RESP_1=$(run_vm "curl -s -X POST http://$CP_IP:8080/v1/functions/$FUNC_NAME:enqueue \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: $IDEM_KEY' \
  -d '{\"input\": {\"test\": \"data\"}}'")

echo -e "\n${CYAN}>>> Risposta 1:${NC} $RESP_1"

log "======================================================"
log "Attendiamo 5 secondi affinché l'esecuzione completi..."
log "======================================================"
sleep 5

log "======================================================"
log "Seconda Invocazione Asincrona (stesso IDEM_KEY)..."
log "======================================================"
RESP_2=$(run_vm "curl -s -X POST http://$CP_IP:8080/v1/functions/$FUNC_NAME:enqueue \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: $IDEM_KEY' \
  -d '{\"input\": {\"test\": \"data\"}}'")

echo -e "\n${CYAN}>>> Risposta 2:${NC} $RESP_2"

log "======================================================"
log "Verifica stato reale dell'esecuzione..."
log "======================================================"
EXEC_ID=$(echo "$RESP_1" | grep -o '"executionId":"[^"]*"' | cut -d'"' -f4)
if [ -n "$EXEC_ID" ]; then
    STATUS_RESP=$(run_vm "curl -s http://$CP_IP:8080/v1/executions/$EXEC_ID")
    echo -e "\n${GREEN}>>> Stato reale dal Gateway:${NC} $STATUS_RESP\n"
else
    warn "Impossibile estrarre l'executionId dalla prima risposta."
fi

if echo "$RESP_2" | grep -q '"queued"'; then
    log "BUG CONFERMATO: La seconda invocazione asincrona ha restituito 'queued' anche se il task era completato!"
else
    log "Wow! La seconda invocazione asincrona NON ha restituito 'queued'!"
fi

log "Test Idempotenza completato con successo."
