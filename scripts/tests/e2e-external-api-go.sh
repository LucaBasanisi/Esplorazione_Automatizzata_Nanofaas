#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

FN_NAME="api-go"
FN_DIR="$PROJECT_DIR/examples/go/$FN_NAME"

log "Configurazione $FN_NAME..."
rm -rf "$FN_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$FN_NAME" --lang go --out "$PROJECT_DIR/examples/go" --yes

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

log "Compilazione binario Go..."
(
    cd "$FN_DIR"
    go get github.com/go-resty/resty/v2
    go mod tidy
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$FN_NAME"
)

# Calcola il percorso relativo per il Dockerfile
REL_FN_DIR=${FN_DIR#$PROJECT_DIR/}

cat <<EOF > "$FN_DIR/Dockerfile"
FROM $BASE_IMAGE
RUN $PKG_UPDATE && $PKG_INSTALL $CA_PKG
WORKDIR /app
COPY $REL_FN_DIR/$FN_NAME /app/$FN_NAME
EXPOSE 8080
ENTRYPOINT ["/app/$FN_NAME"]
EOF

deploy_and_test "$FN_NAME" "$FN_DIR"
