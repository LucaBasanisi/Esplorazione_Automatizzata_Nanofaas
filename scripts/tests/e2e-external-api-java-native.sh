#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

FN_NAME="api-java-native"
FN_DIR="$PROJECT_DIR/functions/java/$FN_NAME"

# --- Gestione GraalVM via SDKMAN ---
export SDKMAN_NON_INTERACTIVE=true
if [ ! -s "$HOME/.sdkman/bin/sdkman-init.sh" ]; then
  log "ERRORE: SDKMAN non trovato. Installa SDKMAN prima di procedere."
  exit 1
fi

set +u
source "$HOME/.sdkman/bin/sdkman-init.sh"
GRAALVM_VERSION=${GRAALVM_VERSION:-}
if [ -z "$GRAALVM_VERSION" ]; then
  GRAALVM_VERSION=$(sdk list java | awk '/-graal/ {print $NF; exit}')
fi

INSTALLED=false
if [ -d "$HOME/.sdkman/candidates/java/$GRAALVM_VERSION" ]; then
  INSTALLED=true
else
  if sdk list java | grep -F "$GRAALVM_VERSION" | grep -q "installed"; then
    INSTALLED=true
  fi
fi

if [ "$INSTALLED" != "true" ]; then
  log "Installazione GraalVM ($GRAALVM_VERSION)..."
  sdk install java "$GRAALVM_VERSION"
fi

sdk use java "$GRAALVM_VERSION"
export JAVA_HOME="$HOME/.sdkman/candidates/java/$GRAALVM_VERSION"
export GRAALVM_HOME="$JAVA_HOME"
set -u
# ----------------------------------

# Fallback for API_URL if not set by Justfile
export API_URL="${API_URL:-https://catfact.ninja/fact}"

log "Configurazione $FN_NAME..."
# Potrebbe esserci la cartella salvata nei test precedenti
rm -rf "$FN_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$FN_NAME" --lang java --yes

# 1. Iniettiamo il plugin GraalVM e la dipendenza di Jackson in build.gradle
# (Usiamo Jackson perché Spring Boot AOT lo supporta nativamente senza hint custom)
sed -i 's/plugins {/plugins {\n    id "org.graalvm.buildtools.native"/g' "$FN_DIR/build.gradle"
sed -i '/dependencies {/a \    implementation "com.fasterxml.jackson.core:jackson-databind"' "$FN_DIR/build.gradle"

handler_path=$(find "$FN_DIR/src/main/java" -name "ApiJavaNativeHandler.java")
package_decl=$(grep "package" "$handler_path" | head -n 1)

# 2. Creiamo l'handler con HttpClient nativo di Java
cat <<EOF > "$handler_path"
$package_decl

import it.unimib.datai.nanofaas.common.model.InvocationRequest;
import it.unimib.datai.nanofaas.common.runtime.FunctionHandler;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Map;
import org.springframework.stereotype.Component;

@Component
public class ApiJavaNativeHandler implements FunctionHandler {
    private final HttpClient client = HttpClient.newBuilder()
        .followRedirects(HttpClient.Redirect.NORMAL)
        .build();
    private final ObjectMapper mapper = new ObjectMapper();

    @Override
    public Object handle(InvocationRequest request) {
        try {
            HttpRequest apiRequest = HttpRequest.newBuilder()
                    .uri(new URI("$API_URL"))
                    .GET()
                    .build();
            HttpResponse<String> response = client.send(apiRequest, HttpResponse.BodyHandlers.ofString());
            return mapper.readValue(response.body(), Map.class);
        } catch (Exception e) {
            return Map.of("error", e.getMessage());
        }
    }
}
EOF

log "Compilazione artefatto Nativo (questo step richiede molta RAM e diversi minuti)..."
# 3. Lanciamo la Native Compilation
(cd "$PROJECT_DIR" && ./gradlew :common:build :sdks:java:build :functions:java:$FN_NAME:nativeCompile)

REL_FN_DIR=${FN_DIR#$PROJECT_DIR/}

# 4. Creiamo un Dockerfile minimale che esegue direttamente il binario
cat <<EOF > "$FN_DIR/Dockerfile"
FROM ubuntu:24.04
WORKDIR /app
COPY $REL_FN_DIR/build/native/nativeCompile/$FN_NAME /app/func
EXPOSE 8080
ENTRYPOINT ["/app/func"]
EOF

log "Deploy ed esecuzione test E2E..."
deploy_and_test "$FN_NAME" "$FN_DIR"
