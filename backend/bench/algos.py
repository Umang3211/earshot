from bench import *
def unit(v): n=np.linalg.norm(v); return v/n if n else v

def online(T, thr, margin=0.08, norm=False, exemplars=False, k=2, warm=0):
    clusters=[]  # dict(raw=list of vecs, cen=vec)
    seen=[]; labels=[]
    for t in T:
        v=t["vec"]
        if v is None: labels.append(None); continue
        seen.append(v); m=np.mean(seen,0) if norm and len(seen)>warm else np.zeros_like(v)
        q=unit(v-m)
        sc=[]
        for i,c in enumerate(clusters):
            if exemplars:
                s=sorted((q@unit(x-m) for x in c["raw"]), reverse=True)[:k]; sc.append((np.mean(s),i))
            else:
                sc.append((q@unit(np.mean(c["raw"],0)-m),i))
        sc.sort(reverse=True)
        if sc and sc[0][0]>=thr and (len(sc)==1 or sc[0][0]-sc[1][0]>=margin):
            i=sc[0][1]; clusters[i]["raw"].append(v); clusters[i]["raw"]=clusters[i]["raw"][-12:]
        else:
            clusters.append({"raw":[v]}); i=len(clusters)-1
        labels.append(i)
    return labels, len(clusters)

def ahc(T, thr, norm=True):
    idx=[i for i,t in enumerate(T) if t["vec"] is not None]
    V=np.array([T[i]["vec"] for i in idx]); m=V.mean(0) if norm else 0
    V=np.array([unit(v-m) for v in V])
    cl=[[i] for i in range(len(V))]
    while len(cl)>1:
        best=(-9,None)
        for a,b in itertools.combinations(range(len(cl)),2):
            s=np.mean(V[cl[a]]@V[cl[b]].T)
            if s>best[0]: best=(s,(a,b))
        if best[0]<thr: break
        a,b=best[1]; cl[a]+=cl[b]; del cl[b]
    lab=[None]*len(T)
    for ci,c in enumerate(cl):
        for j in c: lab[idx[j]]=ci
    return lab,len(cl)

if __name__=="__main__":
    M={m:embed_turns(m) for m in ["ES2004a","IS1009a"]}
    variants={"A current":dict(),"B +room-norm":dict(norm=True),"C +norm+exemplars":dict(norm=True,exemplars=True)}
    for name,kw in variants.items():
        rows=[]
        for thr in np.arange(0.2,0.75,0.05):
            r=[]
            for m,T in M.items():
                lab,n=online(T,thr,**kw); p,c,f=score(T,lab); r.append((f,n))
            rows.append((np.mean([x[0] for x in r]),thr,r))
        best=max(rows)
        print(f"{name:20} best thr {best[1]:.2f}  F {best[0]:.2f}  per meeting " + "  ".join(f"F {f:.2f} ({n} voices)" for f,n in best[2]))
        if name=="A current":
            r=[score(T,online(T,0.42)[0])[2] for T in M.values()]; n=[online(T,0.42)[1] for T in M.values()]
            print(f"{'  A at shipped 0.42':20} F {np.mean(r):.2f}  voices {n}")
    rows=[]
    for thr in np.arange(0.0,0.6,0.05):
        r=[(score(T,ahc(T,thr)[0])[2],ahc(T,thr)[1]) for T in M.values()]; rows.append((np.mean([x[0] for x in r]),thr,r))
    best=max(rows); print(f"{'D offline (best case)':20} best thr {best[1]:.2f}  F {best[0]:.2f}  " + "  ".join(f"F {f:.2f} ({n})" for f,n in best[2]))
