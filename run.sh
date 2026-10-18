#!/bin/sh
# Earshot backend. ./run.sh [stop|status]   TUNNEL=1 ./run.sh for a public URL (cellular).
cd "$(dirname "$0")" || exit 1
mkdir -p .run
PORT=${PORT:-8100}
case "$1" in
  stop) [ -f .run/api.pid ] && kill "$(cat .run/api.pid)" 2>/dev/null; rm -f .run/api.pid
        [ -f .run/tunnel.pid ] && kill "$(cat .run/tunnel.pid)" 2>/dev/null; rm -f .run/tunnel.pid; echo stopped; exit 0 ;;
  status) curl -s -m 2 "localhost:$PORT/health" || echo "not running"; echo; exit 0 ;;
esac
curl -s -m 2 localhost:11434/api/tags >/dev/null || { open -ga Ollama 2>/dev/null || (ollama serve >.run/ollama.log 2>&1 &); sleep 3; }
ollama list | grep -q "${EARSHOT_MODEL:-qwen2.5:7b-instruct}" || ollama pull "${EARSHOT_MODEL:-qwen2.5:7b-instruct}"
if ! curl -s -m 2 "localhost:$PORT/health" >/dev/null; then
  (cd backend || exit 1; nohup .venv/bin/uvicorn earshot:app --host 0.0.0.0 --port "$PORT" >../.run/api.log 2>&1 & echo $! >../.run/api.pid)
  for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -m 1 "localhost:$PORT/health" >/dev/null && break; sleep 1; done
fi
# Warm the model so the first whisper isn't slow.
curl -s localhost:11434/api/generate -d "{\"model\":\"${EARSHOT_MODEL:-qwen2.5:7b-instruct}\",\"prompt\":\"hi\",\"keep_alive\":\"30m\",\"options\":{\"num_predict\":1}}" >/dev/null &
echo "health: $(curl -s localhost:$PORT/health)"
echo "LAN:     http://$(ipconfig getifaddr en0 2>/dev/null):$PORT"
echo "Bonjour: http://$(scutil --get LocalHostName).local:$PORT"
if [ "$TUNNEL" = 1 ]; then
  command -v cloudflared >/dev/null || brew install cloudflared
  nohup cloudflared tunnel --url "http://localhost:$PORT" >.run/tunnel.log 2>&1 & echo $! >.run/tunnel.pid
  for i in $(seq 1 20); do u=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' .run/tunnel.log | head -1); [ -n "$u" ] && break; sleep 1; done
  echo "$u" >.run/tunnel.url; echo "Tunnel:  $u"
fi
