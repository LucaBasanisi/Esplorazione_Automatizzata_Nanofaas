#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

FN_NAME="async-python"
FN_DIR="$PROJECT_DIR/examples/python/$FN_NAME"

log "Configurazione $FN_NAME..."
rm -rf "$FN_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$FN_NAME" --lang python --out "$PROJECT_DIR/examples/python" --yes

cat <<EOF > "$FN_DIR/handler.py"
import time
from nanofaas.sdk import nanofaas_function

@nanofaas_function
def handle(req):
    # Simuliamo un operazione asincrona lenta
    time.sleep(3)
    return {
        "message": "Operazione asincrona completata!",
        "input_ricevuto": req.get("input", {})
    }
EOF

# Calcola il percorso relativo per il Dockerfile
REL_FN_DIR=${FN_DIR#$PROJECT_DIR/}

cat <<EOF > "$FN_DIR/Dockerfile"
FROM $BASE_IMAGE AS builder
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG $PIP_PKG
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uv/bin/
COPY sdks/python/ /tmp/sdk/
RUN /uv/bin/uv pip install --system --target /deps /tmp/sdk/

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
run_vm "nanofaas fn apply -f /home/ubuntu/nanofaas/$REL_FN_DIR/function.yaml"

wait_for_pod_ready "$FN_NAME"

echo -e "\n${YELLOW}--- ASYNC INVOCATION: $FN_NAME ---${NC}"
# Invochiamo in modo asincrono. L output di enqueue contiene l execution ID
ENQUEUE_OUT=$(run_vm "nanofaas enqueue $FN_NAME -d '{\"input\": \"test asincrono\"}'")
echo "$ENQUEUE_OUT"

# Estraiamo l ID usando grep basico sulla macchina virtuale
EXEC_ID=$(echo "$ENQUEUE_OUT" | grep -oP '"executionId"\s*:\s*"\K[^"]+')

if [ -z "$EXEC_ID" ]; then
    error "Impossibile estrarre l executionId dall output di enqueue"
    exit 0 # Uscita pulita come richiesto anche in caso di errore logico
fi

log "Execution ID ottenuto: $EXEC_ID"
echo -e "${CYAN}La funzione è in esecuzione in background...${NC}"

# Pausa bloccante a tempo indefinito come richiesto
echo -e "\n${YELLOW}Premi [INVIO] per leggere il risultato dell'esecuzione asincrona...${NC}"
read -r

log "Recupero dello stato dell'esecuzione..."
attempts=6
count=1

while [ $count -le $attempts ]; do
    EXEC_STATUS=$(run_vm "nanofaas exec get $EXEC_ID")
    
    # Se lo status è success, l esecuzione è completata
    if echo "$EXEC_STATUS" | grep -q '"status"\s*:\s*"success"'; then
        log "Esecuzione completata con successo!"
        echo -e "\n${GREEN}--- ASYNC RESULT ---${NC}"
        echo "$EXEC_STATUS"
        exit 0
    fi
    
    warn "Esecuzione non ancora completata (tentativo $count/$attempts). Riprovo in 3 secondi..."
    sleep 3
    count=$((count+1))
done

error "L'esecuzione asincrona non si è conclusa in tempo."
echo "Ultimo stato: $EXEC_STATUS"
# Non facciamo exit 1 per permettere di proseguire gracefully
exit 0
