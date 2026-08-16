#!/bin/zsh
set -euo pipefail

# Pinned Apache-2.0 Kokoro ONNX assets. Keeping model binaries out of git
# avoids a large source clone while making release builds reproducible.
REVISION="a70f0e45c1cc0df9abdfbfa0f6dee9073579ee99"
BASE_URL="https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/$REVISION"
SCRIPT_DIR="${0:A:h}"
ASSET_DIR="${SCRIPT_DIR:h}/static/models/kokoro"

download() {
  local relative_path="$1"
  local destination="$ASSET_DIR/$relative_path"
  [[ -s "$destination" ]] && return
  mkdir -p "${destination:h}"
  echo "Downloading Kokoro asset: $relative_path"
  /usr/bin/curl --fail --location --retry 3 --retry-delay 2 \
    "$BASE_URL/$relative_path?download=true" --output "$destination"
}

download "config.json"
download "tokenizer.json"
download "tokenizer_config.json"
download "onnx/model_quantized.onnx"

for voice in \
  af_heart af_bella af_nicole af_sarah \
  am_fenrir am_michael bf_emma bm_george; do
  download "voices/$voice.bin"
done

echo "Kokoro assets are ready in $ASSET_DIR"
