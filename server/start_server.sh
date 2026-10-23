#!/usr/bin/env bash
# GhostType · start_server.sh
# Boots a local mlx-lm server that serves short, low-latency completions
# for inline ghost-text suggestions. Apple Silicon only.
#
# Usage:
#   ./start_server.sh                      # first run creates the venv
#   GHOSTTYPE_MODEL=... GHOSTTYPE_PORT=... ./start_server.sh   # model override; default lives in ghosttype_server.py
set -euo pipefail

VENV="$HOME/.venvs/ghosttype"
PORT="${GHOSTTYPE_PORT:-8790}"

if [ ! -d "$VENV" ]; then
  echo "[ghosttype] creating venv at $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip --quiet
  "$VENV/bin/pip" install -r "$(dirname "${BASH_SOURCE[0]}")/requirements.txt" --quiet
fi

# mlx-lm 0.31.x's metadata declares transformers>=5.0.0, but its tokenizer
# registration (AutoTokenizer.register("NewlineTokenizer", ...)) passes a string
# where transformers 5.x expects a class, crashing on import with
# "'str' object has no attribute '__module__'". The last working line is
# transformers 4.x (verified: mlx-lm 0.31.3 + transformers 4.57.6 serves fine;
# pip prints a cosmetic constraint warning). Pin it so a fresh install is born
# correct and a venv that already pulled 5.x self-heals on next start.
# ponytail: cheap import check gates the reinstall — a no-op once pinned. Revisit
# when mlx-lm actually ships transformers-5 support.
if ! "$VENV/bin/python" -c "import sys,transformers; sys.exit(0 if int(transformers.__version__.split('.')[0]) < 5 else 1)" 2>/dev/null; then
  echo "[ghosttype] pinning transformers<5 for mlx-lm compatibility"
  "$VENV/bin/pip" install 'transformers<5' --quiet
fi

# Ensure the custom FIM server's web deps exist (older venvs only had mlx-lm).
if ! "$VENV/bin/python" -c "import fastapi, uvicorn" 2>/dev/null; then
  echo "[ghosttype] installing fastapi + uvicorn for the FIM server"
  "$VENV/bin/pip" install fastapi uvicorn --quiet
fi

echo "[ghosttype] model=${GHOSTTYPE_MODEL:-server default} port=$PORT"
echo "[ghosttype] first launch downloads the model (~300-600MB depending on model)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$VENV/bin/uvicorn" --app-dir "$SCRIPT_DIR" ghosttype_server:app \
  --host 127.0.0.1 --port "$PORT"
