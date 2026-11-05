import math

CP = [(-593.0, 77.0), (-485.0, -422.0), (74.03219943040847, -422.0), (256.0, 78.0)]


def B(t):
    return (
        sum(math.comb(3, i) * (1 - t) ** (3 - i) * t**i * CP[i][0] for i in range(4)),
        sum(math.comb(3, i) * (1 - t) ** (3 - i) * t**i * CP[i][1] for i in range(4)),
    )


TRUE_X = 121.69301292060802


def crossings(pts):
    out = []
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if (y0 + 148) * (y1 + 148) < 0:
            s = (-148 - y0) / (y1 - y0)
            out.append(x0 + s * (x1 - x0))
    return out


def max_sagitta(pts_ts):
    worst = 0.0
    for (t0, p0), (t1, p1) in zip(pts_ts, pts_ts[1:]):
        for k in range(1, 50):
            t = t0 + (t1 - t0) * k / 50
            x, y = B(t)
            vx, vy = p1[0] - p0[0], p1[1] - p0[1]
            L2 = vx * vx + vy * vy
            if L2 > 0:
                s = max(0, min(1, ((x - p0[0]) * vx + (y - p0[1]) * vy) / L2))
            else:
                s = 0
            d = math.hypot(x - (p0[0] + s * vx), y - (p0[1] + s * vy))
            worst = max(worst, d)
    return worst


def report(name, ts):
    pts = [B(t) for t in ts]
    cx = crossings(pts)
    err = cx[-1] - TRUE_X if cx else float("nan")
    sag = max_sagitta(list(zip(ts, pts)))
    print(
        f"{name}: segs={len(ts) - 1} crossings={[round(c, 6) for c in cx]} "
        f"rightErr={err:+.6f} maxSagitta~{sag:.4f} "
        f"zoomFor121px={121 / abs(err) if err else float('inf'):.1f} px/unit"
    )


for n in [8, 12, 16, 32, 64]:
    report(f"uniform n={n}", [i / n for i in range(n + 1)])

diag = math.hypot(256 - (-593), 78 - (-422))
tol = max(0.001, diag / 5000.0)
print(f"diag={diag:.3f} render tol={tol:.6f}")


def dseg(p, a, b):
    vx, vy = b[0] - a[0], b[1] - a[1]
    L2 = vx * vx + vy * vy
    if L2 > 1e-24:
        s = max(0, min(1, ((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / L2))
    else:
        s = 0
    return math.hypot(p[0] - (a[0] + s * vx), p[1] - (a[1] + s * vy))


out = [0.0]


def subdiv(t0, p0, t1, p1, depth):
    tm = (t0 + t1) / 2
    q1 = B(t0 + (t1 - t0) * 0.25)
    mid = B(tm)
    q3 = B(t0 + (t1 - t0) * 0.75)
    flat = max(dseg(q1, p0, p1), dseg(mid, p0, p1), dseg(q3, p0, p1))
    if flat <= tol or depth >= 10:
        out.append(t1)
        return
    subdiv(t0, p0, tm, mid, depth + 1)
    subdiv(tm, mid, t1, p1, depth + 1)


subdiv(0.0, B(0.0), 1.0, B(1.0), 0)
report("adaptive diag/5000 (live renderer)", out)

for z in [1, 2, 5, 10, 50, 100, 450]:
    print(
        f" zoom {z} px/unit: 0.25px = {0.25 / z:.6f} world units sagitta; "
        f"current tol {tol:.4f} = {tol * z:.1f} px sagitta, "
        f"along-line up to {tol * z / 0.731:.1f} px"
    )
