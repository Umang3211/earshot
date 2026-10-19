from algos import *
M={m:embed_turns(m) for m in ['ES2004a','IS1009a']}
def bgset(exclude):
    T=[t for m,TT in M.items() if m!=exclude for t in TT if t['vec'] is not None]
    by=collections.defaultdict(list)
    for t in T: by[t['spk']].append(t['vec'])
    return np.array([v for vs in by.values() for v in vs[:4]])   # 4 turns x 4 speakers
def combo(T, bg, t1, t2):
    idx=[i for i,t in enumerate(T) if t['vec'] is not None]
    V=np.array([T[i]['vec'] for i in idx]); mu=np.vstack([V,bg]).mean(0)
    W=np.array([unit(v-mu) for v in V])
    cl=[[i] for i in range(len(V))]
    def link(a,b): return np.mean(W[cl[a]]@W[cl[b]].T)
    while len(cl)>1:
        s,(a,b)=max((link(a,b),(a,b)) for a,b in itertools.combinations(range(len(cl)),2))
        if s<t1: break
        cl[a]+=cl[b]; del cl[b]
    # merge groups that sound like the same person on the raw voiceprint
    while len(cl)>1:
        s,(a,b)=max((unit(V[cl[a]].mean(0))@unit(V[cl[b]].mean(0)),(a,b)) for a,b in itertools.combinations(range(len(cl)),2))
        if s<t2: break
        cl[a]+=cl[b]; del cl[b]
    lab=[None]*len(T)
    for ci,c in enumerate(cl):
        for j in c: lab[idx[j]]=ci
    return lab,len(cl)
if __name__=="__main__":
    res=[]
    for t1 in (0.0,0.05,0.1):
        for t2 in (0.55,0.6,0.65,0.7,0.75,1.01):
            F=[];single=[]
            for m,T in M.items():
                bg=bgset(m); lab,n=combo(T,bg,t1,t2); F.append(score(T,lab)[2])
                for spk,_ in collections.Counter(t['spk'] for t in T if t['vec'] is not None).most_common(2):
                    S=[t for t in T if t['spk']==spk and t['vec'] is not None][:12]; single.append(combo(S,bg,t1,t2)[1])
            res.append((np.mean(F),t1,t2,single))
            print(f't1 {t1:.2f} t2 {t2:.2f}  meetings F {np.mean(F):.2f}  one-person voices {single}')
