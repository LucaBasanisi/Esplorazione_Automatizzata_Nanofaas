#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

FN_NAME="api-java"
FN_DIR="$PROJECT_DIR/functions/java/$FN_NAME"

log "Configurazione $FN_NAME..."
# Potrebbe esserci la cartella salvata nei test precedenti
rm -rf "$FN_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$FN_NAME" --lang java --yes

sed -i '/dependencies {/a \    implementation "com.squareup.okhttp3:okhttp:4.12.0"\n    implementation "com.google.code.gson:gson:2.10.1"' "$FN_DIR/build.gradle"
# /dependencies {/
# Trova la riga con scritto esattamente: dependencies

# a
# inizia append subito dopo la riga dependencies

# \    implementation ".... \n"
# inserisci questo blocco di codice

# "$FN_DIR/build.gradle"
# Dove effettuare questa 

# Queste variabili non sono necessarie, però:
# - "puliscono" il codice
# - cmq fn-init potrebbe aver sbagliato a generare il percorso/nome
# Solo Java comunque richiede questa "complessità"
handler_path=$(find "$FN_DIR/src/main/java" -name "ApiJavaHandler.java")
package_decl=$(grep "package" "$handler_path" | head -n 1)

# HEREDOC
cat <<EOF > "$handler_path"
$package_decl
import it.unimib.datai.nanofaas.common.model.InvocationRequest;
import it.unimib.datai.nanofaas.common.runtime.FunctionHandler;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import com.google.gson.Gson;
import java.util.Map;
import org.springframework.stereotype.Component;

@Component
public class ApiJavaHandler implements FunctionHandler {
    private final OkHttpClient client = new OkHttpClient();
    private final Gson gson = new Gson();

    @Override
    public Object handle(InvocationRequest request) {
        Request apiRequest = new Request.Builder().url("$API_URL").build();
        try (Response response = client.newCall(apiRequest).execute()) {
            String body = response.body().string();
            return gson.fromJson(body, Map.class);
        } catch (Exception e) {
            return Map.of("error", e.getMessage());
        }
    }
}
EOF

log "Compilazione artefatti Java..."
(cd "$PROJECT_DIR" && ./gradlew :common:build :sdks:java:build :functions:java:$FN_NAME:build)

# Calcola il percorso relativo per il Dockerfile
REL_FN_DIR=${FN_DIR#$PROJECT_DIR/}

cat <<EOF > "$FN_DIR/Dockerfile"
FROM $BASE_IMAGE
RUN $PKG_UPDATE && $PKG_INSTALL $JAVA_PKG
WORKDIR /app
COPY $REL_FN_DIR/build/libs/$FN_NAME.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
EOF

deploy_and_test "$FN_NAME" "$FN_DIR"
