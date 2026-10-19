import numpy as np, soundfile as sf, sherpa_onnx, itertools, pickle, os, io, glob, collections
from bench import rttm, app_turns
SPK="/tmp/claude-501/spk"
MODELS={"titanet":os.path.expanduser("~/earshot/backend/models/nemo_en_titanet_large.onnx"),
 "eres2netv2":f"{SPK}/3dspeaker_speech_eres2netv2_sv_zh-cn_16k-common.onnx",
 "resnet293":f"{SPK}/wespeaker_en_voxceleb_resnet293_LM.onnx","campp":f"{SPK}/wespeaker_en_voxceleb_CAM++_LM.onnx"}
den=sherpa_onnx.OfflineSpeechDenoiser(sherpa_onnx.OfflineSpeechDenoiserConfig(model=sherpa_onnx.OfflineSpeechDenoiserModelConfig(gtcrn=sherpa_onnx.OfflineSpeechDenoiserGtcrnModelConfig(model=f"{SPK}/gtcrn_simple.onnx"))))
EX={k:sherpa_onnx.SpeakerEmbeddingExtractor(sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=p,num_threads=4)) for k,p in MODELS.items()}
def trim(a,sr=16000):
    F=480; n=len(a)//F
    if n<2: return a
    r=np.sqrt((a[:n*F].reshape(n,F)**2).mean(1)); fl,ld=np.percentile(r,[20,90]); g=max(1e-4,min(fl*2,ld*.5))
    return a[:n*F][np.repeat(r>g,F)]
def emb(a):
    out={}
    for tag,x in (("raw",a),("dn",np.asarray(den(a,16000).samples,dtype=np.float32))):
        x=trim(x)
        if len(x)<16000: return None
        for k,ex in EX.items():
            s=ex.create_stream(); s.accept_waveform(16000,x); s.input_finished(); v=np.array(ex.compute(s)); out[(k,tag)]=v/np.linalg.norm(v)
    return out
def data():
    if os.path.exists("sep.pkl"): return pickle.load(open("sep.pkl","rb"))
    D=[]
    for m in ["ES2004a","IS1009a"]:
        a,sr=sf.read(f"{m}.wav",dtype="float32")
        for s,e,c in app_turns(rttm(f"{m}.rttm")):
            spk,d=c.most_common(1)[0]
            if d/sum(c.values())<0.8: continue
            E=emb(a[int(s*sr):int(e*sr)])
            if E: D.append(dict(set=m,spk=spk,E=E))
    bg,_=sf.read("room.wav",dtype="float32"); rng=np.random.default_rng(1)
    for f in sorted(glob.glob(f"{SPK}/clips/*_[1-4].wav")):
        v=os.path.basename(f).split("_")[0]
        if v not in ("Karen","Aman","Albert","Daniel","Samantha","Ralph"): continue
        x,_=sf.read(f,dtype="float32"); s=rng.integers(0,len(bg)-len(x)); nz=bg[s:s+len(x)]
        x=x/np.sqrt((x**2).mean())*np.sqrt((nz**2).mean())*4+nz
        E=emb(x)
        if E: D.append(dict(set="room",spk=v,E=E))
    pickle.dump(D,open("sep.pkl","wb")); return D
def eer(same,diff):
    th=np.linspace(-1,1,801); far=np.array([(diff>=t).mean() for t in th]); frr=np.array([(same<t).mean() for t in th]); i=np.argmin(abs(far-frr)); return (far[i]+frr[i])/2, th[i]
if __name__=="__main__":
    D=data(); print(len(D),"turns", collections.Counter(d["set"] for d in D))
    keys=list(D[0]["E"].keys())
    combos=[[k] for k in keys]+[[("titanet",t),("eres2netv2",t)] for t in ("raw","dn")]+[[("titanet","raw"),("eres2netv2","raw"),("titanet","dn"),("eres2netv2","dn")]]+[[("resnet293",t),("eres2netv2",t)] for t in ("raw","dn")]
    for cb in combos:
        row=[]
        for st in ["ES2004a","IS1009a","room"]:
            S=[d for d in D if d["set"]==st]
            same,diff=[],[]
            for a,b in itertools.combinations(S,2):
                sc=np.mean([a["E"][k]@b["E"][k] for k in cb]); (same if a["spk"]==b["spk"] else diff).append(sc)
            e,t=eer(np.array(same),np.array(diff)); row.append(f"{st} EER {100*e:4.1f}% @{t:.2f}")
        print("+".join(f"{k}/{t}" for k,t in cb).ljust(58), "  ".join(row))
