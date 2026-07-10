#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

FN_NAME="contract-test-python"
FN_DIR="$PROJECT_DIR/examples/python/$FN_NAME"

# ==============================================================================
# FUNZIONE DI CLEANUP (Teardown)
# ==============================================================================
cleanup() {
    log "Pulizia risorse per $FN_NAME..."
    run_vm "nanofaas fn delete $FN_NAME" || true
}
trap cleanup EXIT

log "======================================================"
log "Configurazione $FN_NAME per validazione 'fn test'..."
log "======================================================"
rm -rf "$FN_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$FN_NAME" --lang python --out "$PROJECT_DIR/examples/python" --yes

# 1. Creiamo un Handler che risponde a un input "name"
cat << 'INNER_EOF' > "$FN_DIR/handler.py"
from nanofaas.sdk import nanofaas_function

@nanofaas_function
def handle(req):
    # deploy_and_test fara' un'invocazione base per scaldare il pod.
    # Gestiamo in modo sicuro l'assenza di "name".
    name = req.get("name", "Mondo")
    return {"greeting": f"Ciao, {name}!"}
INNER_EOF

REL_FN_DIR=${FN_DIR#$PROJECT_DIR/}

# 2. Creiamo il Dockerfile standard per Python
cat << INNER_EOF > "$FN_DIR/Dockerfile"
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
INNER_EOF

# 3. Definiamo i Payload per i Test di Contratto
log "Generazione dei payload di contratto..."

cat << 'INNER_EOF' > "$FN_DIR/payloads/happy-path.json"
{
  "description": "Dovrebbe restituire il saluto corretto",
  "input": {
    "name": "nanoFaaS"
  },
  "expected": {
    "greeting": "Ciao, nanoFaaS!"
  }
}
INNER_EOF

cat << 'INNER_EOF' > "$FN_DIR/payloads/failing-path.json"
{
  "description": "Dovrebbe fallire per via di una expected errata",
  "input": {
    "name": "Utente"
  },
  "expected": {
    "greeting": "Questo testo e sbagliato di proposito"
  }
}
INNER_EOF

# Rimuoviamo il file missing-input generato di default per avere un conteggio esatto "1 passed, 1 failed"
rm -f "$FN_DIR/payloads/missing-input.json"


# ==============================================================================
# DEPLOYMENT
# ==============================================================================
# Invochiamo la funzione helper che si occupa di build, push, deploy, wait e dell'invocazione di base
deploy_and_test "$FN_NAME" "$FN_DIR"


# ==============================================================================
# ESECUZIONE DEL TEST DI CONTRATTO
# ==============================================================================
log "======================================================"
log "Esecuzione comando 'nanofaas fn test' (atteso: parziale fallimento)..."
log "======================================================"

# Disabilitiamo 'set -e' temporaneamente perché ci aspettiamo che la CLI fallisca (exit code 1)
set +e
TEST_OUT=$(run_vm "nanofaas fn test $FN_NAME --payloads /home/ubuntu/nanofaas/$REL_FN_DIR/payloads")
TEST_EXIT_CODE=$?
set -e

echo "$TEST_OUT"

# Verifiche finali
if [ $TEST_EXIT_CODE -eq 0 ]; then
    error "Fallimento: il comando 'fn test' ha restituito Exit Code 0, ma ci aspettavamo un fallimento a causa di failing-path.json!"
    exit 1
fi

if echo "$TEST_OUT" | grep -q "1 passed, 1 failed"; then
    log "SUCCESS: La CLI ha validato e riportato correttamente lo stato dei contratti (1 successo, 1 fallimento)."
else
    error "Fallimento: L'output della CLI non corrisponde al riepilogo atteso '1 passed, 1 failed'."
    exit 1
fi

log "======================================================"
log "Validazione comando 'fn test' completata con SUCCESSO!"
log "======================================================"
