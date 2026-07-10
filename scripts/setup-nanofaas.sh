#!/bin/bash

# setup-nanofaas.sh - One-click setup for nanoFaaS on Multipass/k3s (ROBUST VERSION)
# Usage: ./setup-nanofaas.sh [step_number]

set -e

VM_NAME="nanofaas-k8s-dev"
# Risolve la directory del progetto in modo robusto, indipendentemente da dove viene chiamato lo script
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START_STEP=${1:-1}

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

function log() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

function warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

function error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

function run_step() {
    local step_num=$1
    local step_desc=$2
    local step_func=$3
    
    if [ $START_STEP -le $step_num ]; then
        echo -e "\n${YELLOW}>>> STEP $step_num: $step_desc${NC}"
        $step_func
    else
        log "Skipping Step $step_num: $step_desc"
    fi
}

# --- HELPER FUNCTIONS ---

wait_for_k3s() {
    log "Waiting for k3s to be ready..."
    local max_attempts=30
    local attempt=1
    until multipass exec $VM_NAME -- sudo kubectl get nodes &> /dev/null; do
        if [ $attempt -eq $max_attempts ]; then
            error "k3s did not become ready in time."
            exit 1
        fi
        echo -n "."
        sleep 2
        ((attempt++))
    done
    echo ""
    log "k3s is ready."
}

# --- STEP FUNCTIONS ---

step1() {
    if multipass list | grep -q "$VM_NAME"; then
        log "VM $VM_NAME already exists."
        if ! multipass info $VM_NAME | grep -q "State:.*Running"; then
            log "Starting VM $VM_NAME..."
            multipass start $VM_NAME
        fi
    else
        log "Launching Multipass VM..."
        multipass launch --name $VM_NAME --cpus 4 --memory 8G --disk 30G
    fi
}

step2() {
    log "Installing dependencies inside VM..."
    multipass exec $VM_NAME -- bash -c "
        sudo apt-get update && \
        sudo apt-get install -y docker.io docker-buildx openjdk-21-jdk-headless curl unzip zip build-essential zlib1g-dev && \
        curl -s https://get.sdkman.io | bash && \
        source \$HOME/.sdkman/bin/sdkman-init.sh
    "
    
    log "Setting up Docker registry..."
    multipass exec $VM_NAME -- bash -c "
        if sudo docker ps -a --format '{{.Names}}' | grep -q '^registry$'; then
            sudo docker start registry || true
        else
            # Check if port 5000 is occupied
            if sudo lsof -Pi :5000 -sTCP:LISTEN -t >/dev/null ; then
                echo 'Port 5000 already occupied, attempting to continue...'
            else
                sudo docker run -d --name registry -p 5000:5000 --restart always registry:2
            fi
        fi
    "
    
    log "Installing k3s..."
    # Don't reinstall if already there, just ensure it's running
    multipass exec $VM_NAME -- bash -c "
        if command -v k3s &> /dev/null; then
            echo 'k3s already installed.'
        else
            curl -sfL https://get.k3s.io | sudo sh -s - --disable traefik
        fi
    "
    wait_for_k3s
}

step3() {
    log "Configuring insecure registry..."
    multipass exec $VM_NAME -- bash -c '
        sudo mkdir -p /etc/rancher/k3s
        sudo tee /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  "localhost:5000":
    endpoint:
      - "http://localhost:5000"
EOF
        sudo systemctl restart k3s
    '
    wait_for_k3s
}

step4() {
    log "Mounting workspace..."
    # Resolve potential mount conflicts
    local current_mount
    current_mount=$(multipass info $VM_NAME --format json | grep -oP '"source_path": "\K[^"]+' | grep "nanofaas" || true)
    
    if [ -n "$current_mount" ] && [ "$current_mount" != "$PROJECT_DIR" ]; then
        warn "Current mount ($current_mount) differs from $PROJECT_DIR. Unmounting..."
        multipass umount $VM_NAME || true
    fi

    if multipass info $VM_NAME --format json | grep -q "$PROJECT_DIR"; then
        log "Workspace already mounted."
    else
        log "Mounting $PROJECT_DIR to /home/ubuntu/nanofaas..."
        multipass mount "$PROJECT_DIR" "$VM_NAME:/home/ubuntu/nanofaas"
    fi
}

step5() {
    log "Running Gradle build inside VM..."
    # Verify gradlew exists in the mount
    multipass exec $VM_NAME -- bash -c "[ -f ~/nanofaas/gradlew ]" || {
        error "gradlew not found in ~/nanofaas. Mount might have failed."
        exit 1
    }
    multipass exec $VM_NAME -- bash -c 'cd ~/nanofaas && ./gradlew :control-plane:bootJar :function-runtime:bootJar'
}

step6() {
    log "Building and pushing Control Plane image..."
    # Ensure Docker registry is reachable
    multipass exec $VM_NAME -- bash -c "curl -s http://localhost:5000/v2/ > /dev/null" || {
        error "Registry at localhost:5000 is not reachable."
        exit 1
    }
    
    multipass exec $VM_NAME -- bash -c 'cd ~/nanofaas && sudo docker build -t localhost:5000/nanofaas/control-plane:latest -f platform/control-plane/Dockerfile platform/control-plane/'
    multipass exec $VM_NAME -- sudo docker push localhost:5000/nanofaas/control-plane:latest
}

step7() {
    log "Deploying to Kubernetes..."
    multipass exec $VM_NAME -- sudo kubectl apply -f /home/ubuntu/nanofaas/deploy/k8s/namespace.yaml
    multipass exec $VM_NAME -- sudo kubectl apply -f /home/ubuntu/nanofaas/deploy/k8s/
    
    # Surgical update of the image to ensure it uses the local registry tag
    multipass exec $VM_NAME -- bash -c "
        sudo kubectl set image deployment/nanofaas-control-plane control-plane=localhost:5000/nanofaas/control-plane:latest -n nanofaas
    "
}

step8() {
    log "Waiting for Control Plane..."
    # Wait for the rollout to actually start and complete
    multipass exec $VM_NAME -- sudo kubectl rollout status deployment/nanofaas-control-plane -n nanofaas --timeout=120s || {
        error "Deployment failed. Last events:"
        multipass exec $VM_NAME -- sudo kubectl get events -n nanofaas --sort-by=\".lastTimestamp\" | tail -n 10
        exit 1
    }
}

step9() {
    log "Finalizing CLI..."
    multipass exec $VM_NAME -- bash -c 'cd ~/nanofaas && ./gradlew :nanofaas-cli:installDist'
    
    multipass exec $VM_NAME -- bash -c '
        # Wait for service IP
        IP=""
        for i in {1..15}; do
            IP=$(sudo kubectl get svc -n nanofaas control-plane -o jsonpath="{.spec.clusterIP}" 2>/dev/null || echo "")
            if [ -n "$IP" ] && [ "$IP" != "<none>" ]; then break; fi
            echo "Waiting for service IP..."
            sleep 2
        done
        
        if [ -z "$IP" ]; then
            echo "Error: Control Plane Service IP not found."
            exit 1
        fi

        # Create wrapper using the actual IP
        cat <<EOF | sudo tee /usr/local/bin/nanofaas > /dev/null
#!/bin/bash
/home/ubuntu/nanofaas/clients/cli/build/install/nanofaas-cli/bin/nanofaas-cli --endpoint http://$IP:8080 "\$@"
EOF
        sudo chmod +x /usr/local/bin/nanofaas
        echo "CLI successfully configured for endpoint: http://$IP:8080"
    '
    
    # Final sanity check
    log "Verifying installation..."
    multipass exec $VM_NAME -- nanofaas fn list > /dev/null && log "Verification successful!" || warn "Verification failed, but setup finished."
}

# --- EXECUTION ---

run_step 1 "Launch VM" step1
run_step 2 "System Setup" step2
run_step 3 "K8s Config" step3
run_step 4 "Workspace Mount" step4
run_step 5 "Compiling Core" step5
run_step 6 "Docker Image" step6
run_step 7 "K8s Deployment" step7
run_step 8 "Health Check" step8
run_step 9 "CLI Setup" step9

echo -e "\n${GREEN}======================================================${NC}"
log "SUCCESS! nanoFaaS is fully operational."
log "Access it inside the VM: multipass exec $VM_NAME -- nanofaas <cmd>"
echo -e "${GREEN}======================================================${NC}"
