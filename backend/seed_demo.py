"""Seed a running backend with the synthetic demo (two networking nights).
Usage: .venv/bin/python seed_demo.py [http://localhost:8100]"""
import base64, sys, time
import httpx

API = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8100"
w = lambda n: base64.b64encode(open(f"testdata/{n}.wav", "rb").read()).decode()
c = httpx.Client(base_url=API, timeout=60)


def say(s, clip, text):
    r = c.post("/turn", json={"session": s, "text": text, "audio_b64": w(clip)}).json()
    who = (r["person"] or {}).get("name") or r["cluster"] or r["speaker"]
    print(f"{who:12} {r['event']:13} {r['whisper']}")
    return r["session"]


c.post("/enroll_me", json={"audio_b64": w("me_enroll"), "reset": True})
s = say(None, "maya_intro", "Hi, I'm Maya Chen, I'm a product manager at Stripe working on the payments platform team.")
say(s, "me_1", "Nice to meet you. I'm a freshman at Cornell studying information science, and I build hardware hackathon projects.")
say(s, "maya_2", "We just launched a new checkout flow for small businesses and I'm hiring summer interns next month.")
say(s, "arjun_intro", "Honestly the hardest part of legged robots is the contact model, we spend months on it at Carnegie Mellon.")
say(s, "me_1", "Nice to meet you, Arjun. I build hardware hackathon projects.")
say(s, "stranger", "Does anyone know where the coffee is? I have been looking for twenty minutes.")
time.sleep(8)
print(c.post(f"/sessions/{s}/end").json()["whisper"])
s2 = say(None, "maya_later", "Hey, good to see you again! How did that hackathon go in the end?")
say(s2, "arjun_later", "Oh hello again, are you still working on those smart glasses?")
c.post(f"/sessions/{s2}/end")
