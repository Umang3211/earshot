"""Earshot backend: recognise people at a networking event by their voice and
whisper who they are into your AirPods.

The phone streams speech turns (16 kHz WAV + its own on-device transcript).
For every turn we work out who was talking (you, someone you already know, or
a new voice), learn names from introductions, keep notes on what people said,
and decide whether there is something worth whispering.

Run: uvicorn earshot:app --host 0.0.0.0 --port 8100
"""

from __future__ import annotations

import base64
import io
import json
import os
import re
import sqlite3
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

import httpx
import numpy as np
import sherpa_onnx
import soundfile as sf
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

HERE = Path(__file__).parent
DB_PATH = Path(os.environ.get("EARSHOT_DB", HERE / "earshot.db"))
# Two speaker models, fused. On a noisy-room benchmark (10 synthetic voices,
# crowd babble + echo) TitaNet-L alone: 6.3% EER at 10 dB / 18.2% at 3 dB;
# ERes2NetV2: 5.9% / 15.1%; the average of both cosines: 4.5% / 13.5%.
# WeSpeaker ResNet293 (16.9%) and CAM++ (28.9%) were far worse.
VOICE_MODELS = [
    HERE / "models" / "nemo_en_titanet_large.onnx",
    HERE / "models" / "eres2netv2.onnx",
]
OLLAMA = os.environ.get("EARSHOT_OLLAMA", "http://localhost:11434")
MODEL = os.environ.get("EARSHOT_MODEL", "qwen2.5:7b-instruct")
LLM_OFF = os.environ.get("EARSHOT_LLM", "on") == "off"

# Fused score = mean of the two cosines. Benchmark equal-error line sat at
# 0.37-0.47; different people averaged ~0.3, same person ~0.55-0.75. A match
# must clear the line AND beat the runner-up by a margin, so two similar voices
# never get swapped. Recalibrate on real recordings.
VOICE_THRESHOLD = 0.42
VOICE_MARGIN = 0.08
# Backup transcriber for turns that arrive without text (phone speech
# recognition failed or isn't available, e.g. the simulator).
WHISPER_MODEL = os.environ.get("EARSHOT_WHISPER", "small.en")

# Only confident matches update a stored voiceprint.
LEARN_THRESHOLD = 0.50
# Under this much audio the embedding is noise; attribute to the last speaker.
MIN_EMBED_SECONDS = 1.0
# A "nice to meet you, Sam" from the wearer names whoever spoke in this window.
NAMING_WINDOW = 90.0
# Never re-whisper the same person inside one session more often than this.
REWHISPER_AFTER = 15 * 60

app = FastAPI(title="Earshot")
_lock = threading.RLock()
_bg = ThreadPoolExecutor(max_workers=2)


# --------------------------------------------------------------------------
# storage


def db() -> sqlite3.Connection:
    con = sqlite3.connect(DB_PATH, check_same_thread=False)
    con.row_factory = sqlite3.Row
    return con


_con = db()
_con.executescript(
    """
    CREATE TABLE IF NOT EXISTS wearer (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        voice TEXT NOT NULL DEFAULT '[]',
        samples INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS people (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT '',
        org TEXT NOT NULL DEFAULT '',
        facts TEXT NOT NULL DEFAULT '[]',
        followups TEXT NOT NULL DEFAULT '[]',
        voice TEXT NOT NULL DEFAULT '[]',
        voice_n INTEGER NOT NULL DEFAULT 0,
        first_met REAL NOT NULL,
        last_seen REAL NOT NULL,
        times_met INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE IF NOT EXISTS turns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session TEXT NOT NULL,
        ts REAL NOT NULL,
        speaker TEXT NOT NULL,      -- 'me' | 'person' | 'unknown'
        person_id TEXT,
        cluster TEXT,
        text TEXT NOT NULL,
        sim REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        started REAL NOT NULL,
        ended REAL,
        place TEXT NOT NULL DEFAULT ''
    );
    """
)
_con.execute("INSERT OR IGNORE INTO wearer (id) VALUES (1)")
_con.commit()


def _vec(s: str) -> np.ndarray | None:
    v = json.loads(s or "[]")
    return np.asarray(v, dtype=np.float32) if v else None


def _unit(v: np.ndarray) -> np.ndarray:
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else v


def _blend(old: np.ndarray | None, new: np.ndarray, keep: float) -> np.ndarray:
    """Running average of a fused voiceprint, renormalised per model block."""
    if old is None or old.shape != new.shape:
        return new
    mix = keep * old + (1 - keep) * new
    k = len(VOICE_MODELS)
    blocks = np.split(mix, np.cumsum(_block_sizes(mix.shape[0]))[:-1])
    return np.concatenate([_unit(b) / np.sqrt(k) for b in blocks])


_sizes: list[int] = []


def _block_sizes(total: int) -> list[int]:
    if not _sizes:
        _sizes.extend(ex.dim for ex in extractors())
    return _sizes if sum(_sizes) == total else [total]


def person_row(pid: str) -> sqlite3.Row | None:
    return _con.execute("SELECT * FROM people WHERE id = ?", (pid,)).fetchone()


def person_json(r: sqlite3.Row) -> dict:
    return {
        "id": r["id"],
        "name": r["name"],
        "role": r["role"],
        "org": r["org"],
        "facts": json.loads(r["facts"]),
        "followups": json.loads(r["followups"]),
        "has_voice": r["voice_n"] > 0,
        "voice_samples": r["voice_n"],
        "first_met": r["first_met"],
        "last_seen": r["last_seen"],
        "times_met": r["times_met"],
    }


# --------------------------------------------------------------------------
# voice


_extractors: list[sherpa_onnx.SpeakerEmbeddingExtractor] = []


def extractors() -> list[sherpa_onnx.SpeakerEmbeddingExtractor]:
    if not _extractors:
        for m in VOICE_MODELS:
            cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(m), num_threads=4)
            _extractors.append(sherpa_onnx.SpeakerEmbeddingExtractor(cfg))
    return _extractors


def embed(wav: bytes) -> tuple[np.ndarray | None, float]:
    """WAV bytes -> (unit voice embedding, seconds of speech). None when the
    clip is too short or too quiet to say anything about who is talking."""
    audio, sr = sf.read(io.BytesIO(wav), dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    # Trim silence so a long quiet tail doesn't count as speech.
    frame = int(sr * 0.03)
    if len(audio) >= frame:
        n = len(audio) // frame
        rms = np.sqrt((audio[: n * frame].reshape(n, frame) ** 2).mean(axis=1))
        gate = max(0.006, float(np.percentile(rms, 20)) * 2.0)
        voiced = np.repeat(rms > gate, frame)
        speech = audio[: n * frame][voiced]
    else:
        speech = audio
    seconds = len(speech) / sr
    if seconds < MIN_EMBED_SECONDS:
        return None, seconds
    # Each model's unit vector scaled by 1/sqrt(k) and concatenated: the dot
    # product of two of these is exactly the mean of the per-model cosines.
    parts = []
    exs = extractors()
    for ex in exs:
        st = ex.create_stream()
        st.accept_waveform(sr, speech)
        st.input_finished()
        v = _unit(np.asarray(ex.compute(st), dtype=np.float32).flatten())
        parts.append(v / np.sqrt(len(exs)))
    return np.concatenate(parts), seconds


_whisper = None


def transcribe(wav: bytes) -> str:
    global _whisper
    if WHISPER_MODEL == "off":
        return ""
    try:
        if _whisper is None:
            from faster_whisper import WhisperModel
            _whisper = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8")
        audio, sr = sf.read(io.BytesIO(wav), dtype="float32")
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        if sr != 16000:
            audio = np.interp(np.arange(0, len(audio), sr / 16000), np.arange(len(audio)), audio).astype(np.float32)
        segs, _ = _whisper.transcribe(audio, beam_size=1, language="en", vad_filter=True)
        return " ".join(s.text.strip() for s in segs).strip()
    except Exception as e:
        print(f"[earshot] whisper failed: {e}")
        return ""


@app.on_event("startup")
def _warm() -> None:
    # Load both voice models and the transcriber before the first turn.
    _bg.submit(extractors)
    _bg.submit(lambda: transcribe(_silence_wav()))


def _silence_wav() -> bytes:
    b = io.BytesIO()
    sf.write(b, np.zeros(16000, dtype=np.float32), 16000, format="WAV")
    return b.getvalue()


# --------------------------------------------------------------------------
# language: names, profiles, whispers

_NOT_NAMES = {
    "a", "an", "the", "just", "so", "really", "here", "there", "good", "fine",
    "great", "sorry", "not", "from", "with", "at", "in", "on", "working",
    "doing", "going", "looking", "trying", "also", "actually", "still", "new",
    "glad", "happy", "excited", "interested", "currently", "basically", "kind",
    "pretty", "very", "well", "okay", "ok", "sure", "right", "like", "into",
    "studying", "hiring", "building", "running", "leading", "based", "back",
    "sophomore", "junior", "senior", "freshman", "student", "engineer",
}

_INTRO = re.compile(
    r"\b(?i:my name is|my name's|i'm|i am|this is|call me|name's)\s+"
    r"([A-Z][a-zA-Z'\-]+(?:\s+[A-Z][a-zA-Z'\-]+){0,2})"
)
_GREET = re.compile(
    r"\b(?i:nice|great|good|lovely|pleasure) (?i:to )?(?i:meet|meeting) you,?\s+"
    r"([A-Z][a-zA-Z'\-]+(?:\s+[A-Z][a-zA-Z'\-]+)?)"
)
_INTRO_CUE = re.compile(
    r"\b(my name|i'm|i am|this is|call me|name's|nice to meet|work at|working at|"
    r"i run|i lead|i'm at|i study|studying)\b",
    re.I,
)


def _clean_name(raw: str) -> str:
    words = []
    for w in raw.split():
        if w.lower().strip("'") in _NOT_NAMES:
            break
        words.append(w)
    return " ".join(words).strip(" ,.")


def regex_intro(text: str) -> str:
    m = _INTRO.search(text)
    return _clean_name(m.group(1)) if m else ""


def regex_greeting(text: str) -> str:
    m = _GREET.search(text)
    return _clean_name(m.group(1)) if m else ""


def llm_json(system: str, user: str, timeout: float = 20.0) -> dict | None:
    if LLM_OFF:
        return None
    try:
        r = httpx.post(
            f"{OLLAMA}/api/chat",
            json={
                "model": MODEL,
                "stream": False,
                "format": "json",
                "options": {"temperature": 0.1},
                "keep_alive": "30m",
                "messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
            },
            timeout=timeout,
        )
        r.raise_for_status()
        return json.loads(r.json()["message"]["content"])
    except Exception as e:  # model down, timeout, bad JSON
        print(f"[earshot] llm failed: {e}")
        return None


EXTRACT_SYSTEM = (
    "You read one thing a person said out loud at a networking event and pull out "
    "facts about THEM (the speaker). Only record what they actually said; leave a "
    "field empty rather than guess. Never invent a name. Reply with JSON: "
    '{"name": "", "role": "", "org": "", "facts": [], "followups": []}. '
    "name: only if they introduced themselves by name. role: job title or what they "
    "study. org: company, school or lab. facts: short notes worth remembering "
    "(projects, interests, where they're from), max 3, each under 10 words. "
    "followups: concrete next steps the speaker actually mentioned (they're hiring, "
    "asked you to email them, an upcoming event), max 2, each under 10 words; [] if "
    "they mentioned none. Never suggest generic advice like 'ask about projects'."
)


def extract_about(text: str) -> dict:
    out = llm_json(EXTRACT_SYSTEM, text) or {}
    name = str(out.get("name") or "").strip()
    # The model sometimes "finds" a name that is nowhere in the text.
    if name and name.split()[0].lower() not in text.lower():
        name = ""
    if not name:
        name = regex_intro(text)
    role = str(out.get("role") or "").strip()
    org = str(out.get("org") or "").strip()
    # Same for an org that was never said ("Tech Company").
    if org and org.lower() not in text.lower():
        org = ""
    return {
        "name": name,
        "role": role,
        "org": org,
        "facts": [str(f).strip() for f in out.get("facts") or [] if str(f).strip()][:3],
        "followups": [f for f in (str(x).strip() for x in out.get("followups") or [])
                      if f and _grounded(f, text)][:2],
    }


def _grounded(note: str, text: str) -> bool:
    """A follow-up the 7B model invented ("connect for coffee") shares no real
    word with what was said; one it heard ("hiring interns") does."""
    said = {w[:5] for w in re.findall(r"[a-z]{5,}", text.lower())}
    return any(w[:5] in said for w in re.findall(r"[a-z]{5,}", note.lower()))


def _merge_list(old: list[str], new: list[str], cap: int) -> list[str]:
    seen = {s.lower() for s in old}
    out = list(old)
    for s in new:
        if s.lower() not in seen:
            out.append(s)
            seen.add(s.lower())
    return out[-cap:]


def apply_about(pid: str, about: dict) -> None:
    with _lock:
        r = person_row(pid)
        if r is None:
            return
        _con.execute(
            "UPDATE people SET role = ?, org = ?, facts = ?, followups = ? WHERE id = ?",
            (
                # First thing they told us about themselves wins; a later
                # passing remark is not a new job title. Edits go via PATCH.
                r["role"] or about.get("role") or "",
                r["org"] or about.get("org") or "",
                json.dumps(_merge_list(json.loads(r["facts"]), about.get("facts", []), 8)),
                json.dumps(_merge_list(json.loads(r["followups"]), about.get("followups", []), 4)),
                pid,
            ),
        )
        _con.commit()


def headline(r: sqlite3.Row) -> str:
    """'Maya Chen, product manager at Stripe' from whatever we know."""
    bits = r["name"]
    if r["role"] and r["org"]:
        bits += f", {r['role']} at {r['org']}"
    elif r["role"] or r["org"]:
        bits += f", {r['role'] or r['org']}"
    return bits


BRIEF_SYSTEM = (
    "You whisper a reminder into someone's earbud while a person they've met before "
    "starts talking to them. Be brief: at most 22 words, plain spoken English, no "
    "lists or symbols. Start with the person's name. Say who they are, the one most "
    "useful thing from last time, and one thing to ask. Use only the facts given. "
    'Reply with JSON: {"whisper": ""}.'
)


def brief_for(pid: str) -> str:
    r = person_row(pid)
    if r is None:
        return ""
    facts = json.loads(r["facts"])
    ups = json.loads(r["followups"])
    last = _con.execute(
        "SELECT text FROM turns WHERE person_id = ? AND speaker = 'person' "
        "ORDER BY ts DESC LIMIT 6",
        (pid,),
    ).fetchall()
    ctx = {
        "name": r["name"],
        "role": r["role"],
        "org": r["org"],
        "facts": facts,
        "followups": ups,
        "times_met": r["times_met"],
        "what_they_said_before": [t["text"] for t in reversed(last)],
    }
    out = llm_json(BRIEF_SYSTEM, json.dumps(ctx), timeout=12.0)
    w = str((out or {}).get("whisper") or "").strip()
    if w and r["name"].split()[0].lower() in w.lower():
        return w
    # Deterministic fallback: still useful when the model is down.
    w = headline(r) + "."
    if facts:
        w += f" Last time: {facts[-1]}."
    if ups:
        w += f" Follow up: {ups[0]}."
    return w


# --------------------------------------------------------------------------
# sessions (in memory; turns persist in sqlite)


@dataclass
class Cluster:
    label: str
    vec: np.ndarray
    turn_ids: list[int] = field(default_factory=list)
    texts: list[str] = field(default_factory=list)
    last_ts: float = 0.0


@dataclass
class Session:
    id: str
    started: float
    clusters: dict[str, Cluster] = field(default_factory=dict)
    whispered: dict[str, float] = field(default_factory=dict)  # pid -> ts
    met: set[str] = field(default_factory=set)
    last_speaker: tuple[str, str] | None = None  # (kind, pid-or-cluster)
    last_other: tuple[str, str, float] | None = None  # (kind, key, ts)
    voices_seen: int = 0


_sessions: dict[str, Session] = {}


def session(sid: str | None) -> Session:
    with _lock:
        if sid and sid in _sessions:
            return _sessions[sid]
        sid = sid or uuid.uuid4().hex[:12]
        s = Session(id=sid, started=time.time())
        _sessions[sid] = s
        _con.execute(
            "INSERT OR IGNORE INTO sessions (id, started) VALUES (?, ?)", (sid, s.started)
        )
        _con.commit()
        return s


def _find_by_name(name: str) -> sqlite3.Row | None:
    rows = _con.execute("SELECT * FROM people").fetchall()
    n = name.lower()
    for r in rows:
        if r["name"].lower() == n:
            return r
    # "Maya" introduced as just a first name matches a stored "Maya Chen"
    # only when that first name is unique.
    firsts = [r for r in rows if r["name"].lower().split()[0] == n.split()[0]]
    if len(firsts) == 1 and (len(n.split()) == 1 or len(firsts[0]["name"].split()) == 1):
        return firsts[0]
    return None


def _promote(s: Session, cl: Cluster, name: str, now: float) -> tuple[str, bool]:
    """A voice that was unknown in this session now has a name. Returns
    (person id, created)."""
    existing = _find_by_name(name)
    if existing is not None:
        pid = existing["id"]
        old = _vec(existing["voice"])
        _con.execute(
            "UPDATE people SET voice = ?, voice_n = voice_n + 1, last_seen = ? WHERE id = ?",
            (json.dumps(_blend(old, cl.vec, 0.5).tolist()), now, pid),
        )
        created = False
    else:
        pid = uuid.uuid4().hex[:10]
        _con.execute(
            "INSERT INTO people (id, name, voice, voice_n, first_met, last_seen) "
            "VALUES (?, ?, ?, 1, ?, ?)",
            (pid, name, json.dumps(cl.vec.tolist()), now, now),
        )
        created = True
    if cl.turn_ids:
        q = ",".join("?" * len(cl.turn_ids))
        _con.execute(
            f"UPDATE turns SET speaker = 'person', person_id = ? WHERE id IN ({q})",
            (pid, *cl.turn_ids),
        )
    _con.commit()
    s.clusters.pop(cl.label, None)
    s.met.add(pid)
    s.last_other = ("person", pid, now)
    return pid, created


def identify(s: Session, vec: np.ndarray | None) -> tuple[str, str | None, float]:
    """-> (kind, key, sim). kind is 'me' | 'person' | 'cluster' | 'none'."""
    if vec is None:
        if s.last_speaker:
            return s.last_speaker[0], s.last_speaker[1], 0.0
        return "none", None, 0.0
    cands: list[tuple[float, str, str]] = []
    w = _vec(_con.execute("SELECT voice FROM wearer").fetchone()["voice"])
    if w is not None and w.shape == vec.shape:
        cands.append((float(vec @ w), "me", "me"))
    for r in _con.execute("SELECT id, voice FROM people WHERE voice_n > 0"):
        pv = _vec(r["voice"])
        if pv is not None and pv.shape == vec.shape:
            cands.append((float(vec @ pv), "person", r["id"]))
    for c in s.clusters.values():
        cands.append((float(vec @ c.vec), "cluster", c.label))
    cands.sort(reverse=True)
    if cands and cands[0][0] >= VOICE_THRESHOLD:
        best = cands[0]
        runner = next((c for c in cands[1:] if c[2] != best[2]), None)
        if runner is None or best[0] - runner[0] >= VOICE_MARGIN:
            return best[1], best[2], best[0]
    return "cluster", None, cands[0][0] if cands else 0.0


# --------------------------------------------------------------------------
# API


class EnrollIn(BaseModel):
    audio_b64: str
    reset: bool = False


class TurnIn(BaseModel):
    session: str | None = None
    text: str
    audio_b64: str = ""
    ts: float | None = None


class AskIn(BaseModel):
    question: str
    session: str | None = None


class PersonPatch(BaseModel):
    name: str | None = None
    role: str | None = None
    org: str | None = None
    facts: list[str] | None = None
    followups: list[str] | None = None


@app.get("/health")
def health() -> dict:
    w = _con.execute("SELECT samples FROM wearer").fetchone()
    n = _con.execute("SELECT COUNT(*) c FROM people").fetchone()["c"]
    return {"ok": True, "wearer_enrolled": w["samples"] > 0, "people": n, "model": MODEL}


@app.post("/enroll_me")
def enroll_me(body: EnrollIn) -> dict:
    vec, secs = embed(base64.b64decode(body.audio_b64))
    if vec is None:
        raise HTTPException(400, f"only {secs:.1f}s of speech; read for about 10 seconds")
    with _lock:
        row = _con.execute("SELECT voice, samples FROM wearer").fetchone()
        old = None if body.reset else _vec(row["voice"])
        new = _blend(old, vec, 0.6)
        samples = 1 if body.reset else row["samples"] + 1
        _con.execute(
            "UPDATE wearer SET voice = ?, samples = ? WHERE id = 1",
            (json.dumps(new.tolist()), samples),
        )
        _con.commit()
    return {"ok": True, "samples": samples, "seconds": round(secs, 1)}


@app.post("/turn")
def turn(body: TurnIn) -> dict:
    """One stretch of speech. Returns who spoke and, sometimes, a whisper."""
    s = session(body.session)
    now = body.ts or time.time()
    text = body.text.strip()
    vec, secs = (None, 0.0)
    transcribed = False
    if body.audio_b64:
        wav = base64.b64decode(body.audio_b64)
        if os.environ.get("EARSHOT_DUMP"):
            d = Path(os.environ["EARSHOT_DUMP"]); d.mkdir(parents=True, exist_ok=True)
            (d / f"{time.time():.2f}.wav").write_bytes(wav)
        vec, secs = embed(wav)
        if not text and secs >= 0.8:
            text = transcribe(wav)
            transcribed = bool(text)

    with _lock:
        kind, key, sim = identify(s, vec)
        whisper = ""
        event = ""
        pid: str | None = None
        cluster_label: str | None = None
        named_cluster: str | None = None

        if kind == "cluster" and key is None:
            if vec is None:
                kind = "none"
            else:
                s.voices_seen += 1
                label = f"voice {s.voices_seen}"
                s.clusters[label] = Cluster(label=label, vec=vec)
                key = label
        if kind == "cluster":
            cl = s.clusters[key]
            if vec is not None and sim >= LEARN_THRESHOLD:
                cl.vec = _blend(cl.vec, vec, 0.8)
            cluster_label = key
        elif kind == "person":
            pid = key
            if vec is not None and sim >= LEARN_THRESHOLD:
                r = person_row(pid)
                _con.execute(
                    "UPDATE people SET voice = ?, voice_n = voice_n + 1 WHERE id = ?",
                    (json.dumps(_blend(_vec(r["voice"]), vec, 0.9).tolist()), pid),
                )
        elif kind == "me" and vec is not None and sim >= LEARN_THRESHOLD:
            w = _vec(_con.execute("SELECT voice FROM wearer").fetchone()["voice"])
            _con.execute(
                "UPDATE wearer SET voice = ? WHERE id = 1",
                (json.dumps(_blend(w, vec, 0.95).tolist()),),
            )

        speaker = {"me": "me", "person": "person", "cluster": "unknown"}.get(kind, "unknown")
        cur = _con.execute(
            "INSERT INTO turns (session, ts, speaker, person_id, cluster, text, sim) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (s.id, now, speaker, pid, cluster_label, text, round(sim, 3)),
        )
        turn_id = cur.lastrowid
        if kind in ("me", "person", "cluster"):
            s.last_speaker = (kind, key)
        if kind in ("person", "cluster"):
            s.last_other = (kind, key, now)
        if kind == "cluster":
            s.clusters[key].turn_ids.append(turn_id)
            s.clusters[key].texts.append(text)
            s.clusters[key].last_ts = now
        _con.commit()

    # Names. Done outside the lock: the model can take a couple of seconds.
    about: dict | None = None
    if kind == "cluster" and _INTRO_CUE.search(text):
        about = extract_about(text)
        name = about["name"]
        if name:
            with _lock:
                cl = s.clusters.get(key)
                if cl is not None:
                    named_cluster = cl.label
                    pid, created = _promote(s, cl, name, now)
                    apply_about(pid, about)
                    event = "new_person" if created else "voice_linked"
    elif kind == "me" and s.last_other and s.last_other[0] == "cluster":
        name = regex_greeting(text)
        if name and now - s.last_other[2] <= NAMING_WINDOW:
            with _lock:
                cl = s.clusters.get(s.last_other[1])
                if cl is not None:
                    named_cluster = cl.label
                    pid, created = _promote(s, cl, name, now)
                    event = "named_by_you" if created else "voice_linked"
                    # Facts they mentioned before we knew their name.
                    joined = " ".join(cl.texts)
                    if joined:
                        _bg.submit(lambda p=pid, t=joined: apply_about(p, {**extract_about(t), "name": ""}))

    with _lock:
        if pid and kind == "person" and pid not in s.met:
            # A person we already knew, heard for the first time this session.
            s.met.add(pid)
            _con.execute(
                "UPDATE people SET times_met = times_met + 1, last_seen = ? WHERE id = ?",
                (now, pid),
            )
            _con.commit()
            event = "recognised"
        elif pid:
            _con.execute("UPDATE people SET last_seen = ? WHERE id = ?", (now, pid))
            _con.commit()

    if event == "recognised":
        last = s.whispered.get(pid, 0)
        if now - last >= REWHISPER_AFTER:
            whisper = brief_for(pid)
            s.whispered[pid] = now
    elif event in ("new_person", "named_by_you", "voice_linked"):
        r = person_row(pid)
        if event == "voice_linked":
            whisper = f"That's {headline(r)}. Got their voice now."
        else:
            whisper = f"Saved {headline(r)}."
        s.whispered[pid] = now

    # Keep notes on what known people say (async so the reply is fast).
    if kind == "person" and event == "" and len(text.split()) >= 6:
        _bg.submit(lambda p=pid, t=text: apply_about(p, {**extract_about(t), "name": ""}))

    person = person_json(person_row(pid)) if pid else None
    return {
        "session": s.id,
        "turn_id": turn_id,
        "speaker": "me" if kind == "me" else ("person" if pid else "unknown"),
        "cluster": cluster_label if not pid else None,
        "person": person,
        "sim": round(sim, 3),
        "speech_seconds": round(secs, 1),
        "event": event,
        "text": text,
        "transcribed_by": "server" if transcribed else "phone",
        "named_cluster": named_cluster,
        "whisper": whisper,
    }


@app.get("/whois")
def whois(session_id: str) -> dict:
    """'Who am I talking to?' — the AirPods-press lookup."""
    s = _sessions.get(session_id)
    if s is None or s.last_other is None:
        return {"whisper": "I haven't heard anyone else yet."}
    kind, key, ts = s.last_other
    if kind == "person":
        w = brief_for(key)
        s.whispered[key] = time.time()
        return {"whisper": w, "person": person_json(person_row(key))}
    return {"whisper": "Don't know them yet. Ask their name."}


ASK_SYSTEM = (
    "You answer a question about the user's own networking contacts, whispered into "
    "their earbud. Use only the roster given. At most 30 words, spoken English, no "
    "lists. If nobody fits, say so. Reply with JSON: {\"answer\": \"\"}."
)


@app.post("/ask")
def ask(body: AskIn) -> dict:
    rows = _con.execute("SELECT * FROM people ORDER BY last_seen DESC LIMIT 60").fetchall()
    if not rows:
        return {"answer": "You haven't met anyone yet."}
    roster = [
        {
            "name": r["name"],
            "role": r["role"],
            "org": r["org"],
            "facts": json.loads(r["facts"]),
            "followups": json.loads(r["followups"]),
            "last_seen": time.strftime("%b %d", time.localtime(r["last_seen"])),
        }
        for r in rows
    ]
    out = llm_json(ASK_SYSTEM, json.dumps({"question": body.question, "roster": roster}))
    ans = str((out or {}).get("answer") or "").strip()
    return {"answer": ans or "I couldn't work that out right now."}


@app.post("/sessions/{sid}/end")
def end_session(sid: str) -> dict:
    s = _sessions.pop(sid, None)
    _con.execute("UPDATE sessions SET ended = ? WHERE id = ?", (time.time(), sid))
    _con.commit()
    met = [person_row(p) for p in (s.met if s else set())]
    met = [m for m in met if m is not None]
    if not met:
        return {"whisper": "Session ended. No one new.", "people": []}
    names = ", ".join(m["name"] for m in met[:5])
    ups = [f"{m['name'].split()[0]}: {json.loads(m['followups'])[0]}"
           for m in met if json.loads(m["followups"])]
    w = f"You talked with {len(met)} {'person' if len(met) == 1 else 'people'}: {names}."
    if ups:
        w += " Follow ups. " + ". ".join(ups[:3]) + "."
    return {"whisper": w, "people": [person_json(m) for m in met]}


@app.get("/sessions/{sid}")
def get_session(sid: str) -> dict:
    rows = _con.execute(
        "SELECT t.*, p.name FROM turns t LEFT JOIN people p ON p.id = t.person_id "
        "WHERE session = ? ORDER BY ts", (sid,)
    ).fetchall()
    return {
        "session": sid,
        "turns": [
            {"ts": r["ts"], "speaker": r["speaker"], "name": r["name"],
             "cluster": r["cluster"], "text": r["text"], "sim": r["sim"]}
            for r in rows
        ],
    }


@app.get("/people")
def people() -> list[dict]:
    rows = _con.execute("SELECT * FROM people ORDER BY last_seen DESC").fetchall()
    return [person_json(r) for r in rows]


@app.get("/people/{pid}")
def get_person(pid: str) -> dict:
    r = person_row(pid)
    if r is None:
        raise HTTPException(404)
    turns = _con.execute(
        "SELECT ts, text FROM turns WHERE person_id = ? ORDER BY ts DESC LIMIT 30", (pid,)
    ).fetchall()
    return {**person_json(r), "said": [{"ts": t["ts"], "text": t["text"]} for t in turns]}


@app.patch("/people/{pid}")
def patch_person(pid: str, body: PersonPatch) -> dict:
    r = person_row(pid)
    if r is None:
        raise HTTPException(404)
    with _lock:
        for k in ("name", "role", "org"):
            v = getattr(body, k)
            if v is not None:
                _con.execute(f"UPDATE people SET {k} = ? WHERE id = ?", (v.strip(), pid))
        for k in ("facts", "followups"):
            v = getattr(body, k)
            if v is not None:
                _con.execute(f"UPDATE people SET {k} = ? WHERE id = ?", (json.dumps(v), pid))
        _con.commit()
    return person_json(person_row(pid))


@app.delete("/people/{pid}")
def delete_person(pid: str) -> dict:
    with _lock:
        _con.execute("UPDATE turns SET person_id = NULL, speaker = 'unknown' WHERE person_id = ?", (pid,))
        _con.execute("DELETE FROM people WHERE id = ?", (pid,))
        _con.commit()
    return {"ok": True}


@app.get("/sessions")
def list_sessions() -> list[dict]:
    rows = _con.execute("SELECT * FROM sessions ORDER BY started DESC LIMIT 50").fetchall()
    out = []
    for r in rows:
        met = _con.execute(
            "SELECT DISTINCT p.id, p.name FROM turns t JOIN people p ON p.id = t.person_id "
            "WHERE t.session = ?", (r["id"],)
        ).fetchall()
        n = _con.execute("SELECT COUNT(*) c FROM turns WHERE session = ?", (r["id"],)).fetchone()["c"]
        if n == 0:
            continue
        out.append({"id": r["id"], "started": r["started"], "ended": r["ended"], "place": r["place"],
                    "turns": n, "people": [{"id": m["id"], "name": m["name"]} for m in met]})
    return out


@app.get("/graph")
def graph() -> dict:
    """You in the middle, everyone you've met around you, and a link between
    two people when you met them at the same event or they share an org."""
    people_rows = _con.execute("SELECT * FROM people").fetchall()
    nodes = [{"id": "me", "name": "You", "kind": "me"}]
    links = []
    for r in people_rows:
        nodes.append({"id": r["id"], "name": r["name"], "kind": "person", "org": r["org"],
                      "role": r["role"], "times_met": r["times_met"], "has_voice": r["voice_n"] > 0,
                      "followups": len(json.loads(r["followups"]))})
        links.append({"source": "me", "target": r["id"], "kind": "met", "weight": r["times_met"]})
    pairs: dict[tuple[str, str], int] = {}
    for s in _con.execute("SELECT DISTINCT session FROM turns"):
        ids = sorted({t["person_id"] for t in _con.execute(
            "SELECT person_id FROM turns WHERE session = ? AND person_id IS NOT NULL", (s["session"],))})
        for i in range(len(ids)):
            for j in range(i + 1, len(ids)):
                pairs[(ids[i], ids[j])] = pairs.get((ids[i], ids[j]), 0) + 1
    for (a, b), n in pairs.items():
        links.append({"source": a, "target": b, "kind": "same_event", "weight": n})
    by_org: dict[str, list[str]] = {}
    for r in people_rows:
        if r["org"]:
            by_org.setdefault(r["org"].lower(), []).append(r["id"])
    for ids in by_org.values():
        for i in range(len(ids)):
            for j in range(i + 1, len(ids)):
                links.append({"source": ids[i], "target": ids[j], "kind": "same_org", "weight": 1})
    return {"nodes": nodes, "links": links}


WEB = HERE.parent / "web"


@app.get("/", include_in_schema=False)
def site():
    from fastapi.responses import FileResponse
    return FileResponse(WEB / "index.html", headers={"Cache-Control": "no-store"})
