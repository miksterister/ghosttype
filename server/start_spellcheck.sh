#!/usr/bin/env bash
# GhostType · start_spellcheck.sh
# Boots the sentence-level spelling/grammar service (Ollama gemma4 by default,
# or the LFM2.5 GECToR encoder with GHOSTTYPE_SPELL_BACKEND=encoder).
#
# Usage:
#   ./start_spellcheck.sh
#   GHOSTTYPE_SPELL_PORT=8791 GHOSTTYPE_SPELL_MIN_ERROR_PROB=0.7 ./start_spellcheck.sh
set -euo pipefail

# Its own venv, NOT ~/.venvs/ghosttype: that one pins transformers<5 for mlx-lm
# (see start_server.sh), while the optional encoder backend needs transformers 5.x.
VENV="${GHOSTTYPE_SPELL_VENV:-$HOME/.venvs/ghosttype-spell}"
PORT="${GHOSTTYPE_SPELL_PORT:-8791}"

if [ ! -x "$VENV/bin/uvicorn" ]; then
  echo "[ghosttype-spell] creating venv at $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip --quiet
  "$VENV/bin/pip" install fastapi uvicorn requests --quiet
fi

# Default backend is Ollama (only needs HTTP); the encoder backend runs in-process.
if [ "${GHOSTTYPE_SPELL_BACKEND:-ollama}" = "encoder" ] && \
   ! "$VENV/bin/python" -c "import torch, transformers" 2>/dev/null; then
  echo "[ghosttype-spell] installing torch + transformers for the encoder backend"
  "$VENV/bin/pip" install torch 'transformers>=5' --quiet
fi

echo "[ghosttype-spell] port=$PORT backend=${GHOSTTYPE_SPELL_BACKEND:-ollama}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$VENV/bin/uvicorn" --app-dir "$SCRIPT_DIR" spellcheck_server:app \
  --host 127.0.0.1 --port "$PORT"
