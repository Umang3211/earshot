import numpy as np, itertools
from algos import online, ahc, unit
from suites import evaluate

def _ahc_matrix(S, thr):
    cl = [[i] for i in range(len(S))]
    while len(cl) > 1:
        s, (a, b) = max((S[np.ix_(cl[a], cl[b])].mean(), (a, b)) for a, b in itertools.combinations(range(len(cl)), 2))
        if s < thr: break
        cl[a] += cl[b]; del cl[b]
    return cl

def wrap(fn):
    def run(T):
        idx = [i for i, t in enumerate(T) if t["vec"] is not None]
        V = np.array([T[i]["vec"] for i in idx])
        groups = fn(V) if len(V) > 1 else [[0]] * len(V)
        lab = [None] * len(T)
        for g, members in enumerate(groups):
            for j in members: lab[idx[j]] = g
        return lab, len(groups)
    return run

def nme_sc(V, one_thr=None, kmax=8):
    """Spectral clustering with the number of speakers picked from the
    eigengap of a p-neighbour binarised affinity (NME-SC, Park et al. 2020)."""
    n = len(V); S = V @ V.T
    if n <= 2:
        return [[0, 1]] if n == 2 and S[0, 1] > 0.5 else [[i] for i in range(n)]
    best = None
    for p in range(1, max(2, n // 2) + 1):
        A = np.zeros_like(S)
        for i in range(n):
            A[i, np.argsort(-S[i])[:p + 1]] = 1
        A = (A + A.T) / 2
        L = np.diag(A.sum(1)) - A
        ev = np.sort(np.linalg.eigvalsh(L))[: min(kmax, n - 1) + 1]
        gaps = np.diff(ev); k = int(np.argmax(gaps)) + 1
        g = gaps.max() / (ev.max() + 1e-9)
        r = p / (g + 1e-9)
        if best is None or r < best[0]: best = (r, k, A)
    _, k, A = best
    if one_thr is not None and np.mean(S[np.triu_indices(n, 1)]) >= one_thr: k = 1
    if k == 1: return [list(range(n))]
    L = np.diag(A.sum(1)) - A
    w, U = np.linalg.eigh(L); X = U[:, :k]; X = X / (np.linalg.norm(X, axis=1, keepdims=True) + 1e-9)
    # k-means on the spectral embedding
    rng = np.random.default_rng(0); bestl = None
    for _ in range(10):
        C = X[rng.choice(n, k, replace=False)]
        for _ in range(50):
            lab = np.argmax(X @ C.T, 1)
            C = np.array([X[lab == j].mean(0) if (lab == j).any() else C[j] for j in range(k)])
        inertia = sum(np.linalg.norm(X[i] - C[lab[i]]) for i in range(n))
        if bestl is None or inertia < bestl[0]: bestl = (inertia, lab)
    lab = bestl[1]
    return [list(np.where(lab == j)[0]) for j in range(k) if (lab == j).any()]

if __name__ == "__main__":
    for thr in (0.42, 0.5, 0.55):
        evaluate(lambda T, t=thr: online(T, t), f"greedy centroid {thr}")
    for thr in (0.4, 0.45, 0.5):
        evaluate(wrap(lambda V, t=thr: _ahc_matrix(V @ V.T, t)), f"AHC raw {thr}")
    evaluate(wrap(lambda V: nme_sc(V)), "NME spectral")
    for o in (0.45, 0.5, 0.55):
        evaluate(wrap(lambda V, o=o: nme_sc(V, one_thr=o)), f"NME spectral + one-guard {o}")

def ahc_absorb(V, thr, absorb, min_size=2):
    S = V @ V.T
    cl = _ahc_matrix(S, thr)
    big = [c for c in cl if len(c) >= min_size]
    if not big: return cl
    out = [list(c) for c in big]
    for c in cl:
        if len(c) >= min_size: continue
        sims = [S[np.ix_(c, b)].mean() for b in out]
        j = int(np.argmax(sims))
        if sims[j] >= absorb: out[j] += c
        else: out.append(list(c))
    return out
