#!/bin/zsh
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/Offline AI"
HF_MODELS_DIR="${OFFLINE_AI_HF_MODELS_DIR:-/Volumes/Vishwateja/Hugging Face}"
OLLAMA_MODELS_DIR="${OFFLINE_AI_OLLAMA_MODELS_DIR:-/Volumes/Vishwateja/ollama-models}"
if [[ ! -d "$OLLAMA_MODELS_DIR" && -d "/Volumes/Vishwateja/Ollama" ]]; then
  OLLAMA_MODELS_DIR="/Volumes/Vishwateja/Ollama"
fi
OLLAMA_URL="http://127.0.0.1:11434"

if [[ -x "/Applications/Ollama.app/Contents/Resources/ollama" ]]; then
  OLLAMA_BIN="/Applications/Ollama.app/Contents/Resources/ollama"
elif [[ -x "/usr/local/bin/ollama" ]]; then
  OLLAMA_BIN="/usr/local/bin/ollama"
elif [[ -x "/opt/homebrew/bin/ollama" ]]; then
  OLLAMA_BIN="/opt/homebrew/bin/ollama"
else
  echo "Ollama is not installed." >&2
  exit 1
fi

if [[ ! -d "$HF_MODELS_DIR" ]]; then
  echo "Hugging Face directory is unavailable: $HF_MODELS_DIR" >&2
  exit 1
fi

if ! /usr/bin/curl -fsS --max-time 2 "$OLLAMA_URL/api/tags" >/dev/null; then
  echo "Ollama must be running before importing models." >&2
  exit 1
fi

mkdir -p "$APP_SUPPORT/imports"
found=0
imported=0

while IFS= read -r -d '' model_file; do
  found=$((found + 1))
  base_name="${model_file:t:r:l}"
  model_name="hf-${base_name//[^a-z0-9_.-]/-}"
  while [[ "$model_name" == *--* ]]; do model_name="${model_name//--/-}"; done

  if OLLAMA_HOST="$OLLAMA_URL" "$OLLAMA_BIN" show "$model_name" >/dev/null 2>&1; then
    echo "Ready: $model_name"
    continue
  fi

  model_file_spec="$APP_SUPPORT/imports/${model_name}.Modelfile"
  printf 'FROM %s\nPARAMETER num_ctx 4096\n' "$model_file" > "$model_file_spec"
  echo "Importing: $model_name"
  OLLAMA_HOST="$OLLAMA_URL" OLLAMA_MODELS="$OLLAMA_MODELS_DIR" \
    "$OLLAMA_BIN" create "$model_name" -f "$model_file_spec"
  imported=$((imported + 1))
done < <(find "$HF_MODELS_DIR" -maxdepth 2 -type f -iname '*.gguf' -print0)

echo "Checked $found GGUF model(s); imported $imported new model(s)."
