"""Three tests every clustering must pass:
 one   : one person talking alone stays one voice (4 AMI speakers, 12 turns each)
 ami   : 4-person far-field meetings split by person (F score, voice count)
 room  : 3 synthetic voices mixed into the real room recording, interleaved with
         real room turns as unlabelled distractors (F on the 3 voices, count)"""
import io, glob, os, numpy as np, soundfile as sf, collections, pickle
from bench import embed_turns, score, earshot
rng = np.random.default_rng(1)

def ami():
    return {m: embed_turns(m) for m in ["ES2004a", "IS1009a"]}

def one_speaker(M):
    out = []
    for m, T in M.items():
        for spk, _ in collections.Counter(t["spk"] for t in T if t["vec"] is not None).most_common(2):
            out.append([t for t in T if t["spk"] == spk and t["vec"] is not None][:12])
    return out

def room():
    if os.path.exists("room_suite.pkl"): return pickle.load(open("room_suite.pkl", "rb"))
    bg, sr = sf.read("room.wav", dtype="float32")
    T = []
    clips = [f for v in ("Karen", "Aman", "Albert") for f in sorted(glob.glob(f"/tmp/claude-501/spk/clips/{v}_*.wav"))]
    order = rng.permutation(len(clips))
    dist = sorted(glob.glob(os.path.expanduser("~/earshot/.run/turns/*.wav")))
    di = 0
    for k, ci in enumerate(order):
        a, _ = sf.read(clips[ci], dtype="float32")
        s = rng.integers(0, len(bg) - len(a)); noise = bg[s:s + len(a)]
        a = a / np.sqrt((a ** 2).mean()) * np.sqrt((noise ** 2).mean()) * 4  # speech 4x room level (~12 dB)
        mix = a + noise
        b = io.BytesIO(); sf.write(b, mix, sr, format="WAV")
        v, secs = earshot.embed(b.getvalue())
        T.append(dict(vec=v, len=secs, spk=os.path.basename(clips[ci]).split("_")[0]))
        if di < len(dist) and k % 2 == 1:   # a real room turn in between
            v, secs = earshot.embed(open(dist[di], "rb").read()); di += 1
            T.append(dict(vec=v, len=secs, spk="?room"))
    pickle.dump(T, open("room_suite.pkl", "wb")); return T

def score_known(T, labels):
    keep = [(t, l) for t, l in zip(T, labels) if not t["spk"].startswith("?")]
    return score([t for t, _ in keep], [l for _, l in keep])

def evaluate(fn, name):
    M = ami(); R = room()
    ones = [fn(S)[1] for S in one_speaker(M)]
    am = [(score(T, fn(T)[0])[2], fn(T)[1]) for T in M.values()]
    rl, rn = fn(R); rf = score_known(R, rl)[2]
    rk = len({l for t, l in zip(R, rl) if l is not None and not t["spk"].startswith("?")})
    ok = all(o <= 2 for o in ones) and np.mean([f for f, _ in am]) >= 0.8 and rf >= 0.8
    print(f"{name:34} one-person {ones}  AMI F {np.mean([f for f,_ in am]):.2f} voices {[n for _,n in am]}  room F {rf:.2f} (3 voices -> {rk} groups)  {'PASS' if ok else ''}")
