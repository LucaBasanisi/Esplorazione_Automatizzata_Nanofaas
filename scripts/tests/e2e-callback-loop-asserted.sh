#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

FN_NAME="loop-infinito"
FN_DIR="$PROJECT_DIR/examples/python/$FN_NAME"

cleanup() {
    log "Cleanup: rimozione della funzione $FN_NAME (se presente)..."
    run_vm "nanofaas fn delete $FN_NAME 2>/dev/null || true" >/dev/null 2>&1 || warn "Cleanup fallito (non critico)."
}
trap cleanup EXIT

log "Configurazione $FN_NAME per lo stress test del Callback Loop..."
rm -rf "$FN_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$FN_NAME" --lang python --out "$PROJECT_DIR/examples/python" --yes

# Handler che innesca la ricorsione asincrona infinita
cat <<EOF > "$FN_DIR/handler.py"
import requests
import os
from nanofaas.sdk import nanofaas_function

@nanofaas_function
def handle(req):
    exec_id = os.environ.get("EXECUTION_ID", "unknown")
    print(f"--- LOOP ACTIVE: {exec_id} ---")
    
    # Innesca l invocazione successiva chiamando il gateway
    # Usiamo l indirizzo del servizio interno di Kubernetes
    gateway_url = "http://control-plane.nanofaas.svc.cluster.local:8080/v1/functions/$FN_NAME:enqueue"
    
    try:
        # Passiamo un payload minimo per massimizzare la velocità del loop
        requests.post(gateway_url, json={"input": {}}, timeout=5)
    except Exception as e:
        print(f"Loop error: {str(e)}")
        
    return {"status": "recursive_call_sent"}
EOF

# Dockerfile standard per Python
REL_FN_DIR=${FN_DIR#$PROJECT_DIR/}
cat <<EOF > "$FN_DIR/Dockerfile"
FROM $BASE_IMAGE AS builder
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG $PIP_PKG
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uv/bin/
COPY sdks/python/ /tmp/sdk/
RUN /uv/bin/uv pip install --system --target /deps /tmp/sdk/ requests

FROM $BASE_IMAGE
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG
WORKDIR /app
COPY --from=builder /deps $PYTHON_SITE_PATH
COPY $REL_FN_DIR/ /app/
ENV HANDLER_MODULE=handler PORT=8080 PYTHONPATH=/app
EXPOSE 8080
CMD ["python3", "-m", "uvicorn", "nanofaas.runtime.app:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

log "Building and pushing $FN_NAME..."
run_vm "cd ~/nanofaas && sudo docker build -t $REGISTRY/nanofaas/$FN_NAME:latest -f $REL_FN_DIR/Dockerfile ."
run_vm "sudo docker push $REGISTRY/nanofaas/$FN_NAME:latest"

log "Updating manifest and applying..."
sed -i "s|image: .*|image: $REGISTRY/nanofaas/$FN_NAME:latest|" "$FN_DIR/function.yaml"
# Alziamo la concurrency per rendere lo stress test più cattivo
sed -i "s|concurrency: .*|concurrency: 10|" "$FN_DIR/function.yaml"
run_vm "nanofaas fn apply -f /home/ubuntu/nanofaas/$REL_FN_DIR/function.yaml"

wait_for_pod_ready "$FN_NAME"

echo -e "\n${RED}======================================================${NC}"
echo -e "${RED}>>> INNESCO DEL LOOP INFINITO ASINCRONO...           <<<${NC}"
echo -e "${RED}======================================================${NC}"

# Risoluzione dinamica del ClusterIP del Control Plane (cambia ad ogni recreate del pod)
CP_IP=$(run_vm "sudo kubectl get svc -n nanofaas control-plane -o jsonpath='{.spec.clusterIP}'")
log "Control Plane IP: $CP_IP"

# Lanciamo la prima pietra e catturiamo l output per estrarre l executionId
ENQUEUE_OUT=$(run_vm "nanofaas enqueue $FN_NAME -d '{}'")
echo "$ENQUEUE_OUT"

EXEC_ID=$(echo "$ENQUEUE_OUT" | grep -oP '"executionId"\s*:\s*"\K[^"]+' || true)
if [ -z "$EXEC_ID" ]; then
    error "ASSERT FAILED: enqueue non ha restituito un executionId (chiamata non ricevuta)."
    exit 1
fi
log "Execution ID ottenuto: $EXEC_ID"

# Poll: asseriamo che la prima esecuzione raggiunga status=success
log "Attesa completamento della prima esecuzione (max 40s)..."
attempts=20
count=1
FIRST_EXEC_STATUS=""
while [ $count -le $attempts ]; do
    FIRST_EXEC_STATUS=$(run_vm "nanofaas exec get $EXEC_ID" || true)
    if echo "$FIRST_EXEC_STATUS" | grep -q '"status"\s*:\s*"success"'; then
        log "Prima esecuzione $EXEC_ID completata con successo."
        break
    fi
    sleep 2
    count=$((count+1))
done

if ! echo "$FIRST_EXEC_STATUS" | grep -q '"status"\s*:\s*"success"'; then
    error "ASSERT FAILED: la prima esecuzione $EXEC_ID non ha raggiunto 'success' in $((attempts*2))s."
    echo "Ultimo stato: $FIRST_EXEC_STATUS"
    exit 1
fi

# Asserzione: dopo 6 secondi devono esserci almeno N esecuzioni attive
# (cioe il loop si sta propagando). Soglia conservativa.
sleep 6
MIN_CHILDREN=5
COUNT=$(run_vm "sudo kubectl logs -n nanofaas -l function=$FN_NAME --tail=200 | grep -c 'LOOP ACTIVE' || true")
if [ "$COUNT" -lt $((MIN_CHILDREN + 1)) ]; then
    error "ASSERT FAILED: solo $COUNT esecuzioni rilevate dopo 6s (atteso >= $((MIN_CHILDREN + 1))). Il loop non si sta propagando."
    exit 1
fi
log "Loop confermato in propagazione: $COUNT esecuzioni rilevate."

log "Monitoraggio del sistema per 45 secondi..."
DOWN_COUNT=0
DOWN_THRESHOLD=3
for i in {1..15}; do
    echo -e "\n${YELLOW}--- Stato al secondo $((i*3)) ---${NC}"

    # 1. Controlliamo se il Control Plane è ancora vivo (health check)
    if run_vm "curl -s --connect-timeout 2 http://$CP_IP:8081/actuator/health/readiness" | grep -q "UP"; then
        echo -e "${GREEN}[Control Plane] Stato: UP${NC}"
        DOWN_COUNT=0
    else
        echo -e "${RED}[Control Plane] Stato: DOWN o UNREACHABLE!${NC}"
        DOWN_COUNT=$((DOWN_COUNT + 1))
        if [ $DOWN_COUNT -ge $DOWN_THRESHOLD ]; then
            error "ASSERT FAILED: Control Plane DOWN per $DOWN_COUNT iterazioni consecutive. Backpressure non ha retto."
            exit 1
        fi
    fi
    
    # 2. Vediamo se ci sono errori di coda piena nei log
    echo -ne "${CYAN}[Logs] Backpressure check: ${NC}"
    run_vm "sudo kubectl logs -n nanofaas deployment/nanofaas-control-plane --tail=50 | grep -E 'QueueFullException|TOO_MANY_REQUESTS' | tail -n 1 || echo 'Nessun errore di coda rilevato.'"
    
    # 3. Vediamo quante esecuzioni stanno girando (stima dai log dei pod funzione)
    COUNT=$(run_vm "sudo kubectl logs -n nanofaas -l function=$FN_NAME --tail=100 | grep 'LOOP ACTIVE' | wc -l")
    echo -e "${CYAN}[Activity] Circa $COUNT esecuzioni rilevate negli ultimi istanti.${NC}"
    
    sleep 3
done

# Asserzione finale: nessuna chiamata ricorsiva dal handler deve essere fallita
LOOP_ERRORS=$(run_vm "sudo kubectl logs -n nanofaas -l function=$FN_NAME --tail=5000 2>&1 | grep -c 'Loop error' || true")
if [ "$LOOP_ERRORS" -gt 0 ]; then
    error "ASSERT FAILED: $LOOP_ERRORS 'Loop error' rilevati nei log della funzione. Le chiamate ricorsive dal handler sono fallite."
    exit 1
fi
log "Nessun 'Loop error' rilevato: tutte le chiamate ricorsive sono andate a buon fine."

echo -e "\n${GREEN}Stress test completato.${NC}"
echo -e "Se il Control Plane è rimasto UP, i meccanismi di backpressure hanno retto."
echo -e "La funzione $FN_NAME verra eliminata automaticamente dal trap di cleanup."
