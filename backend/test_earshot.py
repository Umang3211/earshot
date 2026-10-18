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
