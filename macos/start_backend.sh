#!/bin/zsh
set -u

RESOURCE_DIR="${0:A:h}"
APP_SUPPORT="$HOME/Library/Application Support/Offline AI"
LOG_DIR="$HOME/Library/Logs/Offline AI"
DATA_DIR="$APP_SUPPORT/data"
OLLAMA_MODELS_DIR="${OFFLINE_AI_OLLAMA_MODELS_DIR:-/Volumes/Vishwateja/ollama-models}"
if [[ ! -d "$OLLAMA_MODELS_DIR" && -d "/Volumes/Vishwateja/Ollama" ]]; then
  OLLAMA_MODELS_DIR="/Volumes/Vishwateja/Ollama"
fi
OLLAMA_URL="http://127.0.0.1:11434"
WEBUI_PORT="17840"

mkdir -p "$APP_SUPPORT" "$LOG_DIR" "$DATA_DIR"
exec >>"$LOG_DIR/backend.log" 2>&1

echo "[$(date)] Starting Offline AI"

SECRET_FILE="$APP_SUPPORT/.webui_secret_key"
if [[ ! -s "$SECRET_FILE" ]]; then
  /usr/bin/openssl rand -base64 32 > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi
export WEBUI_SECRET_KEY="$(tr -d '\r\n' < "$SECRET_FILE")"

if [[ -x "/Applications/Ollama.app/Contents/Resources/ollama" ]]; then
  OLLAMA_BIN="/Applications/Ollama.app/Contents/Resources/ollama"
elif [[ -x "/usr/local/bin/ollama" ]]; then
  OLLAMA_BIN="/usr/local/bin/ollama"
elif [[ -x "/opt/homebrew/bin/ollama" ]]; then
  OLLAMA_BIN="/opt/homebrew/bin/ollama"
else
  OLLAMA_BIN=""
fi

OLLAMA_PID=""
cleanup() {
  if [[ -n "$OLLAMA_PID" ]]; then
    kill "$OLLAMA_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if ! /usr/bin/curl -fsS --max-time 1 "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
  if [[ -n "$OLLAMA_BIN" && -d "$OLLAMA_MODELS_DIR" ]]; then
    echo "Launching Ollama with model store: $OLLAMA_MODELS_DIR"
    env \
      OLLAMA_MODELS="$OLLAMA_MODELS_DIR" \
      OLLAMA_HOST="127.0.0.1:11434" \
      OLLAMA_CONTEXT_LENGTH="4096" \
      OLLAMA_MAX_LOADED_MODELS="1" \
      OLLAMA_NUM_PARALLEL="1" \
      OLLAMA_KEEP_ALIVE="60s" \
      OLLAMA_FLASH_ATTENTION="1" \
      "$OLLAMA_BIN" serve >>"$LOG_DIR/ollama.log" 2>&1 &
    OLLAMA_PID=$!
    for _ in {1..60}; do
      /usr/bin/curl -fsS --max-time 1 "$OLLAMA_URL/api/tags" >/dev/null 2>&1 && break
      sleep 0.5
    done
  else
    echo "Ollama is unavailable. Install Ollama and mount /Volumes/Vishwateja."
  fi
fi

export DATA_DIR
export OLLAMA_BASE_URL="$OLLAMA_URL"
export WEBUI_AUTH="False"
export ENABLE_SIGNUP="False"
export ENABLE_VERSION_UPDATE_CHECK="False"
export ENABLE_COMMUNITY_SHARING="False"
export SCARF_NO_ANALYTICS="True"
export DO_NOT_TRACK="True"
export ANONYMIZED_TELEMETRY="False"
export WEBUI_NAME="Offline AI"
export ENV="prod"
export FROM_INIT_PY="True"
export PYTHONDONTWRITEBYTECODE="1"
export ENABLE_TITLE_GENERATION="False"
export ENABLE_TAGS_GENERATION="False"
export ENABLE_FOLLOW_UP_GENERATION="False"
export ENABLE_AUTOCOMPLETE_GENERATION="False"
export DEFAULT_MODEL_METADATA='{"capabilities":{"builtin_tools":false}}'
export DEFAULT_MODEL_PARAMS='{"think":false}'
export PORT="$WEBUI_PORT"
export HOST="127.0.0.1"
export HF_HOME="$APP_SUPPORT/cache/huggingface"
export SENTENCE_TRANSFORMERS_HOME="$APP_SUPPORT/cache/sentence-transformers"
export WHISPER_MODEL="tiny"
export WHISPER_MODEL_DIR="$DATA_DIR/cache/whisper/models"
export WHISPER_COMPUTE_TYPE="int8"
export WHISPER_MODEL_AUTO_UPDATE="False"
export RAG_EMBEDDING_ENGINE="ollama"
export RAG_EMBEDDING_MODEL="nomic-embed-text"
export RAG_OLLAMA_BASE_URL="$OLLAMA_URL"

PYTHON="$RESOURCE_DIR/python/bin/python3.12"
if [[ ! -x "$PYTHON" ]]; then
  echo "Bundled Python is missing: $PYTHON"
  exit 1
fi

# Config values are persistent in Open WebUI. Apply the offline-first defaults
# to existing installations as well as fresh databases initialized from env.
CONFIG_DB="$DATA_DIR/webui.db"
if [[ -f "$CONFIG_DB" ]] && [[ "$(/usr/bin/sqlite3 "$CONFIG_DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='config';")" == "1" ]]; then
  now="$(date +%s)"
  /usr/bin/sqlite3 "$CONFIG_DB" \
    "BEGIN;
     INSERT INTO config(key,value,updated_at) VALUES('task.title.enable','false',$now) ON CONFLICT(key) DO UPDATE SET value='false',updated_at=$now;
     INSERT INTO config(key,value,updated_at) VALUES('task.tags.enable','false',$now) ON CONFLICT(key) DO UPDATE SET value='false',updated_at=$now;
     INSERT INTO config(key,value,updated_at) VALUES('task.follow_up.enable','false',$now) ON CONFLICT(key) DO UPDATE SET value='false',updated_at=$now;
     INSERT INTO config(key,value,updated_at) VALUES('task.autocomplete.enable','false',$now) ON CONFLICT(key) DO UPDATE SET value='false',updated_at=$now;
     INSERT INTO config(key,value,updated_at) VALUES('models.default_metadata','{\"capabilities\":{\"builtin_tools\":false}}',$now) ON CONFLICT(key) DO UPDATE SET value='{\"capabilities\":{\"builtin_tools\":false}}',updated_at=$now;
     INSERT INTO config(key,value,updated_at) VALUES('models.default_params','{\"think\":false}',$now) ON CONFLICT(key) DO UPDATE SET value='{\"think\":false}',updated_at=$now;
     INSERT INTO config(key,value,updated_at) VALUES('audio.stt.engine','\"\"',$now) ON CONFLICT(key) DO UPDATE SET value='\"\"',updated_at=$now;
     INSERT INTO config(key,value,updated_at) VALUES('audio.stt.whisper_model','\"tiny\"',$now) ON CONFLICT(key) DO UPDATE SET value='\"tiny\"',updated_at=$now;
     COMMIT;"
fi

exec "$PYTHON" -m uvicorn open_webui.main:app --host "$HOST" --port "$PORT" --workers 1
