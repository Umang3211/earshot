"""End-to-end: a fake networking night played through the API with macOS TTS
voices standing in for people (testdata/*.wav, made by make_testdata.sh).

Daniel = the wearer, Karen = Maya Chen, Aman = Arjun, Albert = a stranger.
Runs with the LLM off by default so it is fast and deterministic; set
EARSHOT_TEST_LLM=1 to exercise the local model too.
"""

import base64
import os
import tempfile
from pathlib import Path

import pytest

TD = Path(__file__).parent / "testdata"
os.environ["EARSHOT_DB"] = str(Path(tempfile.mkdtemp()) / "test.db")
if not os.environ.get("EARSHOT_TEST_LLM"):
    os.environ["EARSHOT_LLM"] = "off"

from fastapi.testclient import TestClient  # noqa: E402

import earshot  # noqa: E402

c = TestClient(earshot.app)


def wav(name: str) -> str:
    return base64.b64encode((TD / f"{name}.wav").read_bytes()).decode()


def say(sid, clip, text):
    r = c.post("/turn", json={"session": sid, "text": text, "audio_b64": wav(clip)})
    assert r.status_code == 200, r.text
    return r.json()


def test_regex_names():
    assert earshot.regex_intro("Hi, I'm Maya Chen, I'm a PM") == "Maya Chen"
    assert earshot.regex_intro("I'm a product manager at Stripe") == ""
    assert earshot.regex_intro("My name is Priya Raman and I run a lab") == "Priya Raman"
    assert earshot.regex_intro("I'm just looking for coffee") == ""
    assert earshot.regex_greeting("Nice to meet you, Sam. What do you do?") == "Sam"
    assert earshot.regex_greeting("Great meeting you Jordan Lee") == "Jordan Lee"


def test_networking_night():
    assert c.post("/enroll_me", json={"audio_b64": wav("me_enroll"), "reset": True}).json()["ok"]

    # Night one.
    s1 = None
    r = say(s1, "maya_intro", "Hi, I'm Maya Chen, I'm a product manager at Stripe working on payments.")
    s1 = r["session"]
    assert r["speaker"] == "person" and r["event"] == "new_person"
    assert r["person"]["name"] == "Maya Chen"
    assert r["whisper"].startswith("Saved Maya Chen")

    r = say(s1, "me_1", "Nice to meet you. I'm a freshman at Cornell studying information science.")
    assert r["speaker"] == "me"

    r = say(s1, "maya_2", "We just launched a new checkout flow and I'm hiring summer interns next month.")
    assert r["speaker"] == "person" and r["person"]["name"] == "Maya Chen"
    assert r["whisper"] == ""  # already whispered this session

    # Someone who never says their name, then the wearer names them.
    r = say(s1, "arjun_intro", "Honestly the hardest part of legged robots is the contact model, we spend months on it at Carnegie Mellon.")
    assert r["speaker"] == "unknown" and r["cluster"]
    r = say(s1, "me_1", "Nice to meet you, Arjun. I build hardware hackathon projects.")
    assert r["speaker"] == "me" and r["event"] == "named_by_you"
    assert r["whisper"].startswith("Saved Arjun")

    # A stranger stays a stranger.
    r = say(s1, "stranger", "Does anyone know where the coffee is?")
    assert r["speaker"] == "unknown"

    end = c.post(f"/sessions/{s1}/end").json()
    assert {p["name"] for p in end["people"]} == {"Maya Chen", "Arjun"}

    # Night two: both recognised by voice alone, each whispered once.
    r = say(None, "maya_later", "Hey, good to see you again! How did that hackathon go?")
    s2 = r["session"]
    assert r["speaker"] == "person" and r["person"]["name"] == "Maya Chen"
    assert r["event"] == "recognised" and r["whisper"].startswith("Maya Chen")
    assert r["person"]["times_met"] == 2

    r = say(s2, "arjun_later", "Oh hello again, are you still working on those smart glasses?")
    assert r["person"]["name"] == "Arjun" and r["event"] == "recognised"

    r = say(s2, "maya_later", "Anyway, send me your resume.")
    assert r["person"]["name"] == "Maya Chen" and r["whisper"] == ""

    w = c.get("/whois", params={"session_id": s2}).json()
    assert w["person"]["name"] == "Maya Chen"


def test_short_turn_sticks_to_last_speaker():
    r = say(None, "maya_later", "Hey, good to see you again! How did that hackathon go?")
    sid = r["session"]
    pcm = base64.b64decode(wav("maya_later"))[:44 + 16000]  # half a second
    short = base64.b64encode(pcm).decode()
    r = c.post("/turn", json={"session": sid, "text": "Yeah.", "audio_b64": short}).json()
    assert r["person"]["name"] == "Maya Chen" and r["speech_seconds"] < 1.2


@pytest.mark.skipif(not os.environ.get("EARSHOT_TEST_LLM"), reason="needs local model")
def test_llm_extracts_role_and_org():
    about = earshot.extract_about("Hi, I'm Maya Chen, I'm a product manager at Stripe and we're hiring interns.")
    assert about["name"] == "Maya Chen"
    assert "stripe" in about["org"].lower()


@pytest.mark.skipif(os.environ.get("EARSHOT_WHISPER") == "off", reason="transcriber off")
def test_server_transcribes_when_phone_sends_no_text():
    # Fresh voice, no transcript from the phone: the server hears the name itself.
    earshot._con.execute("DELETE FROM people")
    earshot._con.commit()
    r = c.post("/turn", json={"text": "", "audio_b64": wav("maya_intro")}).json()
    assert r["transcribed_by"] == "server" and "Maya Chen" in r["text"]
    assert r["event"] == "new_person" and r["person"]["name"] == "Maya Chen"


# ---- voice grouping, on voiceprints saved from backend/bench/ --------------
# one0-3: one AMI speaker alone, 12 turns each. room_*: 3 synthetic voices
# mixed into a real room recording plus real room turns ('?room').
# ES2004a/IS1009a: two real 4-person far-field meetings.

import collections as _c
import numpy as _np

_G = _np.load(TD / "voice_groups.npz")


def _f_score(labels, spk, lens):
    w = _c.Counter()
    for l, s, n in zip(labels, spk, lens):
        w[(l, s)] += n
    tot = sum(w.values())
    pur = sum(max(v for (c, _), v in w.items() if c == cl) for cl in {c for c, _ in w}) / tot
    cov = sum(max(v for (_, s), v in w.items() if s == sp) for sp in {s for _, s in w}) / tot
    return 2 * pur * cov / (pur + cov)


def _labels(groups, n):
    lab = [None] * n
    for g, m in enumerate(groups):
        for i in m:
            lab[i] = g
    return lab


def test_one_person_stays_one_voice():
    for k in range(4):
        assert len(earshot.group_voices(_G[f"one{k}"])) == 1, f"speaker {k} split"


def test_three_voices_in_a_real_room_stay_apart():
    V, spk = _G["room_vecs"], _G["room_spk"]
    lab = _labels(earshot.group_voices(V), len(V))
    known = [(l, s) for l, s in zip(lab, spk) if not s.startswith("?")]
    groups = {s: {l for l, s2 in known if s2 == s} for s in {s for _, s in known}}
    assert all(len(g) == 1 for g in groups.values()), groups          # each voice one group
    assert len({next(iter(g)) for g in groups.values()}) == 3          # three different groups


def test_real_meetings_split_by_person():
    fs = []
    for m in ("ES2004a", "IS1009a"):
        V = _G[f"{m}_vecs"]
        lab = _labels(earshot.group_voices(V), len(V))
        fs.append(_f_score(lab, _G[f"{m}_spk"], _G[f"{m}_len"]))
    assert _np.mean(fs) >= 0.80, fs


def test_unnamed_voices_get_stable_separate_labels():
    """No introductions: Maya and Arjun (with room-ish noise) each keep one label."""
    import io
    import soundfile as sf
    rng = _np.random.default_rng(0)

    def noisy(name):
        a, sr = sf.read(TD / f"{name}.wav", dtype="float32")
        a = a + rng.normal(0, _np.sqrt((a ** 2).mean()) / 4, len(a)).astype("float32")
        b = io.BytesIO(); sf.write(b, a, sr, format="WAV")
        return base64.b64encode(b.getvalue()).decode()

    earshot._con.execute("DELETE FROM people")
    earshot._con.commit()
    sid = None
    got = []
    for clip, who in [("maya_2", "maya"), ("arjun_intro", "arjun"), ("maya_later", "maya"),
                      ("arjun_later", "arjun"), ("maya_2", "maya")]:
        r = c.post("/turn", json={"session": sid, "text": "", "audio_b64": noisy(clip)}).json()
        sid = r["session"]
        got.append((who, r["cluster"]))
    s = earshot._sessions[sid]
    final = {tid: cl.label for cl in s.clusters.values() for tid in cl.turn_ids}
    by = _c.defaultdict(set)
    for (who, _), tid in zip(got, sorted(final)):
        by[who].add(final[tid])
    assert len(by["maya"]) == 1 and len(by["arjun"]) == 1 and by["maya"] != by["arjun"], by
