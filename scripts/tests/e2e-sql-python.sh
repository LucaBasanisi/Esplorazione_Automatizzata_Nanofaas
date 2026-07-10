#!/bin/bash
set -eo pipefail
source "$(dirname "$0")/../lib/e2e-utils.sh"

FN_NAME="sql-python"
FN_DIR="$PROJECT_DIR/examples/python/$FN_NAME"

log "Configurazione DB Postgres..."
run_vm "sudo kubectl apply -f /home/ubuntu/nanofaas/postgres-test.yaml"
run_vm "sudo kubectl rollout status deployment/postgres-test -n nanofaas --timeout=120s"
# eh fin qui ci siamo


log "Configurazione $FN_NAME..."
rm -rf "$FN_DIR"
"$PROJECT_DIR/scripts/fn-init.sh" "$FN_NAME" --lang python --out "$PROJECT_DIR/examples/python" --yes

log "Generazione handler.py per $FN_NAME con Pandas e Numpy"
cat <<EOF > "$FN_DIR/handler.py"
from nanofaas.sdk import nanofaas_function, context
import psycopg2
import psycopg2.extras
import os
import pandas as pd
import numpy as np

logger = context.get_logger(__name__)

@nanofaas_function
def handle(input_data):
    exec_id = context.get_execution_id()
    conn = None
    cur = None
    try:
        # 1. Recupero dati dal DB (aumentato a 10.000 righe)
        conn = psycopg2.connect(
            host=os.getenv("DB_HOST"),
            database=os.getenv("DB_NAME"),
            user=os.getenv("DB_USER"),
            password=os.getenv("DB_PASSWORD"),
        )
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM mia_tabella LIMIT 10000")
        risultati = cur.fetchall()
        
        # 2. Elaborazione con Pandas
        df = pd.DataFrame(risultati)
        stats = {
            "mean": float(df["valore"].mean()),
            "std": float(df["valore"].std()),
            "count": len(df)
        }
        
        # 3. Manipolazione Numpy per consumo memoria
        # Creiamo un array da 1.000.000 di elementi (circa 8MB in RAM)
        arr = np.random.rand(1000, 1000)
        reshaped = arr.reshape(500, 2000)
        arr_sum = float(np.sum(reshaped))
        
        logger.info(f"[{exec_id}] Elaborazione completata. Righe: {stats['count']}, Array Sum: {arr_sum}")
        
        return {
            "status": "success",
            "db_stats": stats,
            "numpy_op": {
                "array_shape": reshaped.shape,
                "array_sum": arr_sum
            }
        }
    except Exception as e:
        logger.error(f"[{exec_id}] Errore: {e}")
        raise Exception(f"Errore elaborazione: {e}")
    finally:
        if cur: cur.close()
        if conn: conn.close()
EOF

log "Aggiornamento function.yaml con variabili d'ambiente..."
cat <<EOF >> "$FN_DIR/function.yaml"
env:
  DB_HOST: "postgres-service"
  DB_NAME: "mio_db"
  DB_USER: "postgres"
  DB_PASSWORD: "password123"
EOF
# Curiosità - Come si scrive la password in maniera corretta?
# Uso i Secrets di Kubernetes (ovviamente ora non ha senso, è solo una prova)
# DB_PASSWORD: secretKeyRef: name: db-credentials key: password

# Generazione dockerfile
log "Generazione Dockerfile per $FN_NAME con dipendenze scientifiche..."
REL_FN_DIR=${FN_DIR#$PROJECT_DIR/}
cat <<EOF > "$FN_DIR/Dockerfile"
FROM $BASE_IMAGE AS builder
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG $PIP_PKG $CURL_PKG
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uv/bin/
COPY sdks/python/ /tmp/sdk/
# Installiamo pandas, numpy e psycopg2-binary
RUN /uv/bin/uv pip install --system --target /deps /tmp/sdk/ psycopg2-binary pandas numpy

FROM $BASE_IMAGE
RUN $PKG_UPDATE && $PKG_INSTALL $PYTHON_PKG
WORKDIR /app
COPY --from=builder /deps $PYTHON_SITE_PATH
COPY $REL_FN_DIR/ /app/
ENV HANDLER_MODULE=handler PORT=8080 PYTHONPATH=/app
EXPOSE 8080
CMD ["python3", "-m", "uvicorn", "nanofaas.runtime.app:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

deploy_and_test "$FN_NAME" "$FN_DIR"
