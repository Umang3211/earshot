import sys, numpy as np, soundfile as sf, itertools, collections, pickle, os
sys.path.insert(0, os.path.expanduser("~/earshot/backend")); os.environ["EARSHOT_DB"]="/tmp/claude-501/ami/x.db"
import earshot

def rttm(p):
    s=[]
    for l in open(p):
        f=l.split(); s.append((float(f[3]),float(f[3])+float(f[4]),f[7]))
    return sorted(s)

def app_turns(segs):
    """Merge speech the way the phone does: a turn ends after 1.0 s quiet (2.2 s if under 3 s), ceiling 15 s."""
    turns=[]; cur=None
    for a,b,spk in segs:
        if cur is None: cur=[a,b,collections.Counter()]
        else:
            gap=a-cur[1]; length=cur[1]-cur[0]
            need=2.2 if length<3 else 1.0
            if gap>=need or (b-cur[0])>15: turns.append(cur); cur=[a,b,collections.Counter()]
            else: cur[1]=max(cur[1],b)
        cur[2][spk]+=b-a
    turns.append(cur); return turns

def embed_turns(meeting):
    cache=f"{meeting}.emb.pkl"
    if os.path.exists(cache): return pickle.load(open(cache,"rb"))
    audio,sr=sf.read(f"{meeting}.wav",dtype="float32")
    out=[]
    for a,b,c in app_turns(rttm(f"{meeting}.rttm")):
        clip=audio[int(a*sr):int(b*sr)]
        import io; buf=io.BytesIO(); sf.write(buf,clip,sr,format="WAV")
        v,secs=earshot.embed(buf.getvalue())
        spk,dur=c.most_common(1)[0]
        out.append(dict(t=a,len=b-a,spk=spk,purity=dur/sum(c.values()),vec=v))
    pickle.dump(out,open(cache,"wb")); return out

def score(turns, labels):
    """Duration-weighted: purity (each cluster = mostly one person) and coverage
    (each person = mostly one cluster). F = harmonic mean."""
    w=collections.Counter(); 
    for t,l in zip(turns,labels):
        if l is not None: w[(l,t["spk"])]+=t["len"]
    tot=sum(w.values())
    pur=sum(max(v for (c,s),v in w.items() if c==cl) for cl in {c for c,_ in w})/tot
    cov=sum(max(v for (c,s),v in w.items() if s==sp) for sp in {s for _,s in w})/tot
    return pur,cov,2*pur*cov/(pur+cov)
