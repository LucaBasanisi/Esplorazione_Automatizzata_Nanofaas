#!/bin/bash

# Questo file ha come unico scopo quello di contenere le "funzioni" che gli altri script dovranno usare
# In pratica serve a "pulire" il codice e renderlo più leggibile

# Si aspetta che le variabili di configurazione (VM_NAME, REGISTRY, ecc.)
# siano presenti nell'ambiente (es. esportate da un Justfile).

# Codici colore ANSI
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- FUNZIONI PER LO SCRIPT ---
function log()   { echo -e "${GREEN}[INFO] $1${NC}"; }
function warn()  { echo -e "${YELLOW}[WARN] $1${NC}"; }
function error() { echo -e "${RED}[ERROR] $1${NC}"; }
function debug() { echo -e "${CYAN}[DEBUG] $1${NC}"; }

# --- INTERAGIRE CON MULTIPASS ---
function run_vm() { 
    multipass exec "$VM_NAME" -- bash -c "$1"
}

# --- VARIABILI GLOBALI - DISTRIBUZIONE LINUX ---
# Queste sono solo variabili che non verranno necessariamente usate dallo script
# Se sto testando python non mi usaerò mai JAVA_PKG
if [ "$SELECTED_DISTRO" = "alpine" ]; then
    BASE_IMAGE="alpine:3.20"
    PKG_UPDATE="apk add --no-cache"
    PKG_INSTALL="apk add --no-cache"
    PYTHON_PKG="python3"
    PIP_PKG="py3-pip"
    CURL_PKG="curl"
    JAVA_PKG="openjdk21-jre"
    CA_PKG="ca-certificates"
    PYTHON_SITE_PATH="/usr/lib/python3.12/site-packages/"
else
    BASE_IMAGE="ubuntu:24.04"
    PKG_UPDATE="apt-get update"
    PKG_INSTALL="apt-get install -y"
    PYTHON_PKG="python3"
    PIP_PKG="python3-pip"
    CURL_PKG="curl"
    JAVA_PKG="openjdk-21-jre-headless"
    CA_PKG="ca-certificates"
    PYTHON_SITE_PATH="/usr/local/lib/python3.12/dist-packages/"
fi

# --- FUNZIONI CORE DEL TEST ---
# "copiate" dal file TLDR_nanofaas.txt 

wait_for_pod_ready() {
    local fn_name=$1
    local timeout=120
    log "Waiting for $fn_name pod to be ready..."
    run_vm "sudo kubectl rollout status deployment/fn-$fn_name -n nanofaas --timeout=${timeout}s"
    
    log "Checking /health endpoint for $fn_name..."
    local attempts=4
    local count=1
    while [ $count -le $attempts ]; do
        local pod_ip
        pod_ip=$(run_vm "sudo kubectl get pod -n nanofaas -l function=$fn_name -o jsonpath='{.items[0].status.podIP}'" 2>/dev/null || true)
        if [ -n "$pod_ip" ]; then
            if run_vm "curl -s http://$pod_ip:8080/health" | grep -q "ok"; then
                log "$fn_name is healthy!"
                return 0
            fi
        fi
        sleep 3
        count=$((count+1))
    done
    error "$fn_name failed to become healthy."
    return 1
}

deploy_and_test() {
    local fn_name=$1
    local fn_dir=$2
    
    # Calcola il percorso relativo rispetto alla root del progetto per l'uso nella VM
    local rel_fn_dir=${fn_dir#$PROJECT_DIR/}
    
    log "Building and pushing $fn_name..."
    if [ -f "$fn_dir/Dockerfile" ] && grep -qE "COPY.*function-sdk-go" "$fn_dir/Dockerfile"; then
        # Caso speciale Go V2: serve accesso al SDK locale
        run_vm "cd ~/nanofaas && sudo docker build -t $REGISTRY/nanofaas/$fn_name:latest -f $rel_fn_dir/Dockerfile --build-context sdk=sdks/go ."
    elif [ -f "$fn_dir/Dockerfile" ] && grep -qE "COPY.*sdks/python" "$fn_dir/Dockerfile"; then
        run_vm "cd ~/nanofaas && sudo docker build -t $REGISTRY/nanofaas/$fn_name:latest -f $rel_fn_dir/Dockerfile ."
    elif [ -f "$fn_dir/Dockerfile" ] && grep -qE "COPY $rel_fn_dir" "$fn_dir/Dockerfile"; then
        run_vm "cd ~/nanofaas && sudo docker build -t $REGISTRY/nanofaas/$fn_name:latest -f $rel_fn_dir/Dockerfile ."
    else
        run_vm "cd ~/nanofaas/$rel_fn_dir && sudo docker build -t $REGISTRY/nanofaas/$fn_name:latest ."
    fi
    run_vm "sudo docker push $REGISTRY/nanofaas/$fn_name:latest"
    
    log "Updating manifest and applying..."
    sed -i "s|image: .*|image: $REGISTRY/nanofaas/$fn_name:latest|" "$fn_dir/function.yaml"
    run_vm "nanofaas fn apply -f /home/ubuntu/nanofaas/$rel_fn_dir/function.yaml"
    
    wait_for_pod_ready "$fn_name"
    
    echo -e "\n${YELLOW}--- INVOCATION RESULT: $fn_name ---${NC}"
    run_vm "nanofaas invoke $fn_name -d '{}'"
}
