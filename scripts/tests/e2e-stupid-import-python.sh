#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

FN_NAME="stupid-import-python"
FN_DIR="$PROJECT_DIR/examples/python/$FN_NAME"

log "Configurazione $FN_NAME..."
rm -rf "$FN_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$FN_NAME" --lang python --out "$PROJECT_DIR/examples/python" --yes

cat <<EOF > "$FN_DIR/handler.py"
from nanofaas.sdk import nanofaas_function

@nanofaas_function
def handle(req):
    # Dipingiamo lo scenario insidioso: l'import è dentro la funzione
    # ma il modulo non esiste proprio nell'immagine.
    import non_existent_module
    
    return {"status": "success"}
EOF

# Calcola il percorso relativo per il Dockerfile
REL_FN_DIR=${FN_DIR#$PROJECT_DIR/}

cat <<EOF > "$FN_DIR/Dockerfile"
FROM $BASE_IMAGE AS builder
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG $PIP_PKG $CURL_PKG
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uv/bin/
COPY sdks/python/ /tmp/sdk/
# INSTALLAZIONE BASE, VOLUTAMENTE SENZA 'requests'
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

# Il pod partirà correttamente perché l'import mancante è "nascosto" dentro handle().
# Il readiness probe (su /health) risponderà 200 OK.
wait_for_pod_ready "$FN_NAME"

log "Esecuzione PRIMA invocazione (Cold Start) - Ci aspettiamo un 500 con ModuleNotFoundError..."
set +e
FIRST_RES=$(run_vm "nanofaas invoke $FN_NAME -d '{}'" 2>&1)
set -e

echo -e "\n${YELLOW}--- RISPOSTA INVOCAZIONE 1 ---${NC}"
echo "$FIRST_RES"

# Verifichiamo che l'output contenga la traccia dell'errore
log "Verifica presenza errore nel body..."
if echo "$FIRST_RES" | grep -aiE "ModuleNotFoundError|non_existent"; then
    log "OK: Errore modulo mancante intercettato correttamente alla prima invocazione."
else
    error "FAIL: Il body di risposta non contiene il traceback o il nome del modulo mancante!"
    exit 1
fi

log "Esecuzione SECONDA invocazione (Warm Mode)..."
set +e
SECOND_RES=$(run_vm "nanofaas invoke $FN_NAME -d '{}'" 2>&1)
set -e

echo -e "\n${YELLOW}--- RISPOSTA INVOCAZIONE 2 ---${NC}"
echo "$SECOND_RES"

# Verifichiamo che l'errore sia consistente
if echo "$SECOND_RES" | grep -aiE "ModuleNotFoundError|non_existent"; then
    log "OK: L'errore persiste coerentemente in WARM mode (nessuna cache anomala)."
else
    error "FAIL: Il comportamento è cambiato al secondo tentativo o l'errore è stato nascosto!"
    exit 1
fi

log "Test $FN_NAME completato con successo!"
