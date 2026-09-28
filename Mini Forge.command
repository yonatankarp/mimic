#!/usr/bin/env bash
# Double-click to start Mini Forge and open it in the browser. Close this window to stop it.
cd "$(dirname "$0")"
( sleep 1; open http://127.0.0.1:8765 ) &
exec python3 ui/serve.py
