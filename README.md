# Earshot

Networking memory that runs on your voice instead of your face. Your iPhone's
mic listens, Earshot works out who's talking by their voiceprint, learns names
from introductions, and whispers who someone is into your AirPods.

## Run

```
./run.sh            # backend + website on :8100 (Ollama qwen2.5:7b, no API key)
TUNNEL=1 ./run.sh   # plus a public trycloudflare URL for cellular
./run.sh stop
```

Website / network map: http://localhost:8100 (or the LAN/Bonjour URL run.sh prints).

iOS: `cd ios && xcodegen generate && open Earshot.xcodeproj`, run on your iPhone
(Developer Mode on, first build from Xcode to mint the profile). Setup tab: set
the backend URL, then record your voice once.

## How it works

- **Capture:** iPhone built-in mic (AirPods mics beamform toward you and suppress
  the other person). AirPods stay in A2DP for output.
- **Turns:** 0.8 s of quiet ends a turn; on-device speech recognition + 16 kHz audio.
- **Who's talking:** fused TitaNet-L + ERes2NetV2 voice embeddings (sherpa-onnx).
  Best of four models on a noisy-room benchmark; see VOICE_MODELS in backend/earshot.py.
  Match needs score ≥ 0.42 and a 0.08 lead over the runner-up.
- **Names:** "Hi, I'm Maya Chen" from a new voice, or you saying "nice to meet
  you, Arjun" names the voice that just spoke.
- **Whispers:** new person saved, known person recognised (once per session),
  AirPods press = who is this, double press = ask a question. Never plays on
  the speaker.
- **Notes:** role, org, facts and follow-ups pulled by the local LLM, gated so it
  can't invent orgs or follow-ups that weren't said.

## Test

```
cd backend && .venv/bin/python -m pytest -q        # scenario with synthetic voices
EARSHOT_TEST_LLM=1 .venv/bin/python -m pytest -q   # include the local model
.venv/bin/python seed_demo.py                      # fill a running backend with the demo
```

Simulator: the mic deadlocks Core Audio there, so launch with `-rehearse` to
push Documents/script.txt clips through the real app pipeline.

Models (not in git) go in backend/models/: nemo_en_titanet_large.onnx and
eres2netv2.onnx (sherpa-onnx speaker-recongition-models release).
