#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

# questa variabile viene "presa" dal comando: just setup step="1"
START_STEP=${1:-1}

# Se il setup di nanofaas è fallito in uno STEP successivo, per evitare di fare tutto da capo
# possiamo digitare "just setup 3"
# 1. Se START_STEP > 1, saltiamo la logica degli snapshot e andiamo dritti al setup manuale
if [ "$START_STEP" -gt 1 ]; then
    warn "Ripresa del setup manuale dallo step $START_STEP..."
    "$PROJECT_DIR/scripts/setup-nanofaas.sh" "$START_STEP"
    # Dopo il setup manuale forziamo la creazione dello snapshot alla fine
    CREATE_SNAPSHOT_FLAG=true
else
    # Se ho fatto semplicemente "just setup"
    if ! multipass info "$VM_NAME" >/dev/null 2>&1; then
        warn "VM $VM_NAME non trovata. Avvio setup completo..."
        "$PROJECT_DIR/scripts/setup-nanofaas.sh" "1"
        log "Creazione snapshot di base '$SNAPSHOT_NAME'..."
        multipass stop "$VM_NAME"
        multipass snapshot "$VM_NAME" --name "$SNAPSHOT_NAME"
        multipass start "$VM_NAME"
    else
        # 2. Ripristino automatico snapshot per ambiente pulito
        # Usiamo jq per una ricerca (parsing) del JSON degli snapshot (funziona come sed, ma per JSON)
        if multipass info "$VM_NAME" --snapshots --format json 2>/dev/null | jq -e ".info.\"$VM_NAME\".snapshots.\"$SNAPSHOT_NAME\"" > /dev/null; then
            log "Ripristino dello snapshot '$SNAPSHOT_NAME' per garantire un ambiente pulito..."
            multipass stop "$VM_NAME"
            multipass restore "$VM_NAME.$SNAPSHOT_NAME" --destructive
            log "Avvio della VM $VM_NAME dopo il ripristino..."
            multipass start "$VM_NAME"
            log "Attesa inizializzazione file system condiviso (mount)..."
            for i in {1..30}; do
                if multipass exec "$VM_NAME" --working-dir /home/ubuntu -- bash -c "test -d /home/ubuntu/nanofaas/scripts" 2>/dev/null; then
                    break
                fi
                sleep 1
            done
        else
            warn "Snapshot '$SNAPSHOT_NAME' non trovato. Procedo con setup-nanofaas per riparare/completare."
            # Se la VM esiste ma non c'è lo snapshot, è probabile (facciamo sicuro) che il comando precedente sia fallito
            "$PROJECT_DIR/scripts/setup-nanofaas.sh" "1"
            CREATE_SNAPSHOT_FLAG=true
        fi
    fi
fi

# 3. Assicuriamoci che il montaggio del workspace sia avvenuto (senza quello schifo di jq)
log "Verifica montaggio workspace su $VM_NAME..."
if ! multipass info "$VM_NAME" --format json | grep -q '"source_path": "'"$PROJECT_DIR"'"'; then
    log "Montaggio di $PROJECT_DIR su $VM_NAME..."
    multipass mount "$PROJECT_DIR" "$VM_NAME:/home/ubuntu/nanofaas"
fi
# tutto ciò che mettiamo tra `...` viene trattato come testo letterale
# questo quindi non va bene: grep -q '"source_path": "$PROJECT_DIR"'

# Ma che è sto schifo? Perché dovrei usare jq?
# multipass info "$VM_NAME" --format json | jq -e '.info."$PROJECT_DIR".mounts // {} | .[] | select(.source_path == "$PROJECT_DIR")' > /dev/null


# 4. Verifica la salute dei servizi kubernetes
log "Verifica salute del cluster e dei servizi..."
run_vm "sudo kubectl wait --for=condition=Ready nodes --all --timeout=60s" >/dev/null

# Verifica che il namespace esista (potrebbe mancare se il setup è rotto)
# get ns -> get namespaces
if ! run_vm "sudo kubectl get ns nanofaas > /dev/null 2>&1"; then
    error "Namespace 'nanofaas' non trovato. Il setup potrebbe non essere completo."
    exit 1
fi

if ! run_vm "curl -s http://localhost:5000/v2/ > /dev/null"; then
    error "Registry Docker non raggiungibile su localhost:5000!"
    exit 1
fi

log "Attesa che nanofaas-control-plane sia pronto..."
run_vm "sudo kubectl rollout status deployment/nanofaas-control-plane -n nanofaas --timeout=60s" >/dev/null

log "Configurazione finale Port-Forward per il Control Plane (API e Management)..."
# Chiudiamo eventuali tunnel precedenti e avviamo il nuovo tunnel come servizio di sistema
# Usiamo [k]ubectl per evitare che pkill uccida la propria sessione (errore 255)
run_vm "sudo pkill -9 -f '[k]ubectl port-forward' || true"
run_vm "sudo systemctl stop nanofaas-port-forward.service > /dev/null 2>&1 || true"
run_vm "sudo systemctl reset-failed nanofaas-port-forward.service > /dev/null 2>&1 || true"

# Usiamo il deployment, indirizzo 0.0.0.0 e kubeconfig esplicito.
# Aggiungiamo Restart=always così systemd riprova automaticamente se il pod non è ancora pronto.
run_vm "sudo systemd-run --unit=nanofaas-port-forward --property=Restart=always --property=RestartSec=2 --property=StartLimitIntervalSec=0 /usr/local/bin/kubectl port-forward --address 0.0.0.0 -n nanofaas deployment/nanofaas-control-plane 8080:8080 8081:8081 --kubeconfig /etc/rancher/k3s/k3s.yaml"

# Verifica finale del tunnel con ciclo di retry
log "Verifica finale connettività al Control Plane (porta 8080 e 8081)..."
TUNNEL_OK=false
for i in {1..30}; do
    # Verifichiamo prima la salute (readiness) sulla porta 8081, poi l'API sulla 8080 (tramite tunnel e tramite ClusterIP)
    IP=$(run_vm "sudo kubectl get svc -n nanofaas control-plane -o jsonpath='{.spec.clusterIP}'" 2>/dev/null || echo "")
    if [ -n "$IP" ] && \
       run_vm "curl -s --connect-timeout 2 http://localhost:8081/actuator/health/readiness | grep -q 'UP'" && \
       run_vm "curl -s --connect-timeout 2 http://localhost:8080/v1/functions > /dev/null" && \
       run_vm "curl -s --connect-timeout 2 http://$IP:8080/v1/functions > /dev/null"; then
        TUNNEL_OK=true
        log "Tunnel stabilito e Control Plane pronto!"
        break
    fi
    warn "Control Plane non ancora pronto (tentativo $i/30), attesa..."
    sleep 4
done

if [ "$TUNNEL_OK" = false ]; then
    error "Errore: Tunnel Port-Forward non funzionante dopo vari tentativi!"
    log "Log del servizio per diagnosi:"
    run_vm "sudo journalctl -u nanofaas-port-forward.service --no-pager -n 20"
    exit 1
fi

# 5. Creazione snapshot se richiesto
# "copiato" da TLDR_nanofaas.txt
if [ "${CREATE_SNAPSHOT_FLAG:-false}" = true ]; then
    log "Creazione dello snapshot '$SNAPSHOT_NAME' su ambiente verificato..."
    multipass stop "$VM_NAME"
    multipass snapshot "$VM_NAME" --name "$SNAPSHOT_NAME"
    multipass start "$VM_NAME"
    log "Attesa riavvio dei servizi Kubernetes dopo lo snapshot..."
    for i in {1..30}; do
        if run_vm "sudo kubectl get nodes" >/dev/null 2>&1; then break; fi
        sleep 2
    done
    run_vm "sudo kubectl wait --for=condition=Ready nodes --all --timeout=120s" >/dev/null
    run_vm "sudo kubectl rollout status deployment/nanofaas-control-plane -n nanofaas --timeout=120s" >/dev/null
fi

log "Setup completato con successo e ambiente verificato."
