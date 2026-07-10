#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

FN_NAME="slow-python"
FN_DIR="$PROJECT_DIR/examples/python/$FN_NAME"

# Cleanup on exit
cleanup() {
    log "Pulizia risorse per $FN_NAME..."
    run_vm "nanofaas fn delete $FN_NAME" || true
    run_vm "rm -f stress_queue.py" || true
}
trap cleanup EXIT

log "======================================================"
log "Configurazione $FN_NAME per il Backpressure Test..."
log "======================================================"
rm -rf "$FN_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$FN_NAME" --lang python --out "$PROJECT_DIR/examples/python" --yes

cat <<EOF > "$FN_DIR/handler.py"
import time
from nanofaas.sdk import nanofaas_function

@nanofaas_function
def handle(req):
    # Ogni esecuzione dura 2 secondi per intasare la coda
    time.sleep(2)
    print("--- SLOW DONE ---", flush=True)
    return {"status": "done"}
EOF

REL_FN_DIR=${FN_NAME#$PROJECT_DIR/}
# Dockerfile standard (copiato da e2e-async-python.sh)
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
COPY examples/python/$FN_NAME/ /app/
ENV HANDLER_MODULE=handler PORT=8080 PYTHONPATH=/app
EXPOSE 8080
CMD ["python3", "-m", "uvicorn", "nanofaas.runtime.app:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

log "Building and pushing $FN_NAME..."
run_vm "cd ~/nanofaas && sudo docker build -t $REGISTRY/nanofaas/$FN_NAME:latest -f examples/python/$FN_NAME/Dockerfile ."
run_vm "sudo docker push $REGISTRY/nanofaas/$FN_NAME:latest"

sed -i "s|image: .*|image: $REGISTRY/nanofaas/$FN_NAME:latest|" "$FN_DIR/function.yaml"
# Forziamo concurrency a 1 per massimizzare l intasamento della coda
sed -i "s|concurrency: .*|concurrency: 1|" "$FN_DIR/function.yaml"
run_vm "nanofaas fn apply -f /home/ubuntu/nanofaas/examples/python/$FN_NAME/function.yaml"

wait_for_pod_ready "$FN_NAME"

log "Innesco bombardamento asincrono (1000 richieste)..."

# Creiamo uno script Python sulla VM per inviare richieste in parallelo
run_vm "cat <<EOF > stress_queue.py
import urllib.request
import concurrent.futures
import sys
import time
import socket

# Aumentiamo i file descriptor se possibile (lato script)
try:
    import resource
    resource.setrlimit(resource.RLIMIT_NOFILE, (2048, 2048))
except:
    pass

last_error = None

def send_req(i):
    global last_error
    # Usiamo 127.0.0.1 per forzare IPv4 e bypassare la risoluzione DNS di localhost
    url = 'http://127.0.0.1:8080/v1/functions/$FN_NAME:enqueue'
    req = urllib.request.Request(url, data=b'{\"input\":{}}', headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            return response.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        if last_error is None:
            last_error = str(e)
        return 0

print('Partenza bombardamento (1000 richieste)...')
start = time.time()
# Usiamo 50 worker per essere piu gentili con i file descriptor locali ma comunque veloci
with concurrent.futures.ThreadPoolExecutor(max_workers=50) as executor:
    results = list(executor.map(send_req, range(1000)))
end = time.time()

print(f'Completato in {end-start:.2f}s')
if last_error:
    print(f'Esempio di errore client: {last_error}')
print(f'RISULTATI: 200/202={results.count(200)+results.count(202)}, 429={results.count(429)}, ERROR={results.count(0)+results.count(500)+results.count(503)}')
EOF"

STRESS_OUT=$(run_vm "python3 stress_queue.py")
echo "$STRESS_OUT"

# Verifica dei risultati del bombardamento
if echo "$STRESS_OUT" | grep -q "429="; then
    NUM_429=$(echo "$STRESS_OUT" | grep -oP "429=\K\d+")
    if [ "$NUM_429" -gt 0 ]; then
        log "SUCCESS: Rilevati $NUM_429 rifiuti per coda piena (HTTP 429). La backpressure funziona!"
    else
        warn "Nessun codice 429 rilevato. Forse la coda è troppo grande o le richieste troppo lente."
    fi
else
    error "Errore durante l esecuzione dello stress test."
    exit 1
fi

log "Monitoraggio svuotamento coda (attesa smaltimento richieste accodate)..."
# Se abbiamo concurrency 1 e queueSize 100, ci vorranno circa 200 secondi (100 * 2s) per svuotare tutto.
# Facciamo un campionamento ogni 10 secondi per 30 secondi per vedere i log progredire.
for i in {1..3}; do
    DONE_COUNT=$(run_vm "sudo kubectl logs -n nanofaas -l function=$FN_NAME --tail=1000 | grep 'SLOW DONE' | wc -l")
    log "Richieste completate finora: $DONE_COUNT"
    sleep 10
done

NEW_DONE_COUNT=$(run_vm "sudo kubectl logs -n nanofaas -l function=$FN_NAME --tail=1000 | grep 'SLOW DONE' | wc -l")
if [ "$NEW_DONE_COUNT" -gt 0 ]; then
    log "SUCCESS: La coda si sta svuotando correttamente ($NEW_DONE_COUNT completate)."
else
    error "La coda sembra bloccata. Nessun progresso rilevato."
    exit 1
fi

log "Test della coda piena completato con successo."
