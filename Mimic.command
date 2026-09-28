#!/usr/bin/env bash
# Start Mimic and open it in the browser. The Mimic app in Applications runs this too.
cd "$(dirname "$0")"
URL=http://127.0.0.1:8765
# Already running (a second double-click, or the app): just show it.
if curl -fs -o /dev/null "$URL/api/job"; then open "$URL"; exit 0; fi
( for _ in $(seq 50); do curl -fs -o /dev/null "$URL/api/job" && { open "$URL"; exit; }; sleep 0.2; done ) &
exec image-to-3dlab/.venv/bin/python ui/serve.py
