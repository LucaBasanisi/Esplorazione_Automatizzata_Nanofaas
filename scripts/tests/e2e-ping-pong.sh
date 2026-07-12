#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

log "======================================================"
log "Configurazione CALLBACK_URL globale per il namespace 'nanofaas'..."
log "======================================================"
CP_IP=$(run_vm "sudo kubectl get svc -n nanofaas control-plane -o jsonpath='{.spec.clusterIP}'")
log "Control Plane IP rilevato: $CP_IP"

run_vm "sudo kubectl set env deployment/nanofaas-control-plane CALLBACK_URL=http://$CP_IP:8080/v1/internal/executions -n nanofaas"
run_vm "sudo kubectl rollout status deployment/nanofaas-control-plane -n nanofaas --timeout=60s"
sleep 5

PING_NAME="ping-python"
PONG_NAME="pong-python"
PING_DIR="$PROJECT_DIR/examples/python/$PING_NAME"
PONG_DIR="$PROJECT_DIR/examples/python/$PONG_NAME"

# ==============================================================================
# FUNZIONE 1: PING (Python)
# ==============================================================================
log "======================================================"
log "Configurazione $PING_NAME (Python)..."
log "======================================================"
rm -rf "$PING_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$PING_NAME" --lang python --out "$PROJECT_DIR/examples/python" --yes

cat <<EOF > "$PING_DIR/handler.py"
import time
import requests
from nanofaas.sdk import nanofaas_function, context

@nanofaas_function
def handle(req):
    # NOTA: L SDK spacchetta gia la chiave 'input', quindi req e direttamente il nostro payload
    count = req.get("count", 0)
    exec_id = context.get_execution_id()
    
    print(f"--- PING ACTIVE: count={count}, exec_id={exec_id} ---", flush=True)
    
    if count > 0:
        # Piccolo delay per rendere i log leggibili e non saturare la coda istantaneamente
        time.sleep(2)
        url = "http://$CP_IP:8080/v1/functions/$PONG_NAME:enqueue"
        try:
            # Dobbiamo avvolgere in 'input' perche stiamo chiamando le API del Gateway direttamente
            next_request = {"input": {"count": count - 1}}
            resp = requests.post(url, json=next_request, timeout=5)
            print(f"PING: Enqueued PONG successfully with count={count-1} (Status: {resp.status_code})", flush=True)
        except Exception as e:
            print(f"PING: Failed to enqueue PONG - {e}", flush=True)
            
    return {"status": "ping_done", "count": count}
EOF

REL_PING_DIR=${PING_DIR#$PROJECT_DIR/}
cat <<EOF > "$PING_DIR/Dockerfile"
FROM $BASE_IMAGE AS builder
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG $PIP_PKG
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uv/bin/
COPY sdks/python/ /tmp/sdk/
RUN /uv/bin/uv pip install --system --target /deps /tmp/sdk/ requests

FROM $BASE_IMAGE
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG
WORKDIR /app
COPY --from=builder /deps $PYTHON_SITE_PATH
COPY $REL_PING_DIR/ /app/
ENV HANDLER_MODULE=handler PORT=8080 PYTHONPATH=/app
EXPOSE 8080
CMD ["python3", "-m", "uvicorn", "nanofaas.runtime.app:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

log "Building and pushing $PING_NAME..."
run_vm "cd ~/nanofaas && sudo docker build -t $REGISTRY/nanofaas/$PING_NAME:latest -f $REL_PING_DIR/Dockerfile ."
run_vm "sudo docker push $REGISTRY/nanofaas/$PING_NAME:latest"

sed -i "s|image: .*|image: $REGISTRY/nanofaas/$PING_NAME:latest|" "$PING_DIR/function.yaml"
run_vm "nanofaas fn apply -f /home/ubuntu/nanofaas/$REL_PING_DIR/function.yaml"


# ==============================================================================
# FUNZIONE 2: PONG (Python)
# ==============================================================================
log "======================================================"
log "Configurazione $PONG_NAME (Python)..."
log "======================================================"
rm -rf "$PONG_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$PONG_NAME" --lang python --out "$PROJECT_DIR/examples/python" --yes

cat <<EOF > "$PONG_DIR/handler.py"
import time
import requests
from nanofaas.sdk import nanofaas_function, context

@nanofaas_function
def handle(req):
    count = req.get("count", 0)
    exec_id = context.get_execution_id()
    
    print(f"--- PONG ACTIVE: count={count}, exec_id={exec_id} ---", flush=True)
    
    if count > 0:
        time.sleep(2)
        url = "http://$CP_IP:8080/v1/functions/$PING_NAME:enqueue"
        try:
            next_request = {"input": {"count": count - 1}}
            resp = requests.post(url, json=next_request, timeout=5)
            print(f"PONG: Enqueued PING successfully with count={count-1} (Status: {resp.status_code})", flush=True)
        except Exception as e:
            print(f"PONG: Failed to enqueue PING - {e}", flush=True)
            
    return {"status": "pong_done", "count": count}
EOF

REL_PONG_DIR=${PONG_DIR#$PROJECT_DIR/}
cat <<EOF > "$PONG_DIR/Dockerfile"
FROM $BASE_IMAGE AS builder
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG $PIP_PKG
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uv/bin/
COPY sdks/python/ /tmp/sdk/
RUN /uv/bin/uv pip install --system --target /deps /tmp/sdk/ requests

FROM $BASE_IMAGE
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG
WORKDIR /app
COPY --from=builder /deps $PYTHON_SITE_PATH
COPY $REL_PONG_DIR/ /app/
ENV HANDLER_MODULE=handler PORT=8080 PYTHONPATH=/app
EXPOSE 8080
CMD ["python3", "-m", "uvicorn", "nanofaas.runtime.app:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

log "Building and pushing $PONG_NAME..."
run_vm "cd ~/nanofaas && sudo docker build -t $REGISTRY/nanofaas/$PONG_NAME:latest -f $REL_PONG_DIR/Dockerfile ."
run_vm "sudo docker push $REGISTRY/nanofaas/$PONG_NAME:latest"

sed -i "s|image: .*|image: $REGISTRY/nanofaas/$PONG_NAME:latest|" "$PONG_DIR/function.yaml"
run_vm "nanofaas fn apply -f /home/ubuntu/nanofaas/$REL_PONG_DIR/function.yaml"


log "======================================================"
log "Attesa avvio pod..."
log "======================================================"
wait_for_pod_ready "$PING_NAME"
wait_for_pod_ready "$PONG_NAME"

echo -e "\n${YELLOW}>>> INNESCO DEL PING-PONG ASINCRONO (Countdown da 10) <<<${NC}"
# La CLI avvolge automaticamente il payload in 'input'
run_vm "nanofaas enqueue $PING_NAME -d '{\"count\": 10}'"

log "Monitoraggio del Ping-Pong per 30 secondi..."
for i in {1..15}; do
    echo -e "\n${CYAN}--- $PING_NAME Logs ---${NC}"
    run_vm "sudo kubectl logs -n nanofaas -l function=$PING_NAME --tail=20 | grep 'PING ACTIVE' | tail -n 1 || true"
    
    echo -e "\n${GREEN}--- $PONG_NAME Logs ---${NC}"
    run_vm "sudo kubectl logs -n nanofaas -l function=$PONG_NAME --tail=20 | grep 'PONG ACTIVE' | tail -n 1 || true"
    
    sleep 2
done

echo -e "\n${YELLOW}Verifica completamento...${NC}"
# Verifichiamo se almeno uno dei due e arrivato a 0
if run_vm "sudo kubectl logs -n nanofaas -l function=$PING_NAME --tail=100" | grep -q "count=0"; then
    log "SUCCESS: Ping-Pong completato con successo!"
elif run_vm "sudo kubectl logs -n nanofaas -l function=$PONG_NAME --tail=100" | grep -q "count=0"; then
    log "SUCCESS: Ping-Pong completato con successo!"
else
    error "Il Ping-Pong non ha raggiunto lo zero."
fi
