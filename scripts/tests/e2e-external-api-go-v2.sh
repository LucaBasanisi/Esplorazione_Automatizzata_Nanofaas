#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

FN_NAME="api-go"
FN_DIR="$PROJECT_DIR/examples/go/$FN_NAME"

log "Configurazione $FN_NAME (Versione 2 - Multi-stage/Scratch)..."
rm -rf "$FN_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$FN_NAME" --lang go --out "$PROJECT_DIR/examples/go" --yes

# Generazione del sorgente Go
# Nota: le variabili $API_URL e $FN_NAME vengono espanse all'esecuzione dello script
cat <<EOF > "$FN_DIR/main.go"
package main
import (
	"context"
	"encoding/json"
	"github.com/go-resty/resty/v2"
	"github.com/miciav/nanofaas/function-sdk-go/nanofaas"
)
func Handle(ctx context.Context, req nanofaas.InvocationRequest) (any, error) {
	client := resty.New()
	resp, err := client.R().SetContext(ctx).Get("$API_URL")
	if err != nil { return map[string]interface{}{"error": err.Error()}, nil }
	var result map[string]interface{}
	json.Unmarshal(resp.Body(), &result)
	return result, nil
}
func main() {
	rt := nanofaas.NewRuntime()
	rt.Register("$FN_NAME", Handle)
	rt.Start(context.Background())
}
EOF

log "Aggiornamento moduli Go (sull'host per coerenza cache)..."
(
    cd "$FN_DIR"
    go get github.com/go-resty/resty/v2
    go mod tidy
)

log "Generazione Dockerfile Multi-Stage (Scratch)..."
# Creiamo un .dockerignore per velocizzare e proteggere la build
cat <<EOF > "$FN_DIR/.dockerignore"
.git
.venv
node_modules
build
EOF

# Il Dockerfile ora usa un named context per il SDK
cat <<EOF > "$FN_DIR/Dockerfile"
# Stage 1: Build isolata
FROM golang:1.25-alpine AS builder
WORKDIR /app

# Installiamo i certificati per le chiamate TLS
RUN apk add --no-cache ca-certificates

# Copiamo il SDK Go dal named context 'sdk'
COPY --from=sdk / /sdks/go/

# Copiamo il sorgente della funzione (context corrente: cartella funzione)
COPY . .

# Compilazione statica
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o $FN_NAME main.go

# Stage 2: Runtime minimale
FROM scratch
WORKDIR /app
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /app/$FN_NAME /app/$FN_NAME

EXPOSE 8080
ENTRYPOINT ["/app/$FN_NAME"]
EOF

deploy_and_test "$FN_NAME" "$FN_DIR"
