import mpmath as mp

mp.mp.dps = 50
CP = [
    (mp.mpf(-593), mp.mpf(77)),
    (mp.mpf(-485), mp.mpf(-422)),
    (mp.mpf("74.03219943040847"), mp.mpf(-422)),
    (mp.mpf(256), mp.mpf(78)),
]


def B(t):
    x = sum(mp.binomial(3, i) * (1 - t) ** (3 - i) * t**i * CP[i][0] for i in range(4))
    y = sum(mp.binomial(3, i) * (1 - t) ** (3 - i) * t**i * CP[i][1] for i in range(4))
    return x, y


f = lambda t: B(t)[1] + 148
roots = []
N = 20000
prev = (mp.mpf(0), f(mp.mpf(0)))
for k in range(1, N + 1):
    t = mp.mpf(k) / N
    v = f(t)
    if prev[1] == 0:
        roots.append(prev[0])
    elif v == 0 or (v < 0) != (prev[1] < 0):
        a, b = prev[0], t
        for _ in range(200):
            m = (a + b) / 2
            if (f(m) < 0) == (f(a) < 0):
                a = m
            else:
                b = m
        roots.append((a + b) / 2)
    prev = (t, v)

print("roots y=-148:")
for t in roots:
    x, y = B(t)
    print(f" t={mp.nstr(t, 20)} point=({mp.nstr(x, 20)},{mp.nstr(y, 20)})")

stored = mp.mpf("121.693012920608")
print("stored after-trim line end x =", stored)
for t in roots:
    x, y = B(t)
    print(f" overshoot vs root t={mp.nstr(t, 8)}: storedX-trueX = {mp.nstr(stored - x, 20)}")


def dist2(t):
    x, y = B(t)
    return (x - stored) ** 2 + (y + 148) ** 2


best = min((dist2(mp.mpf(k) / 20000), mp.mpf(k) / 20000) for k in range(20001))
print("closest-curve-distance warning: coarse grid only, not the exact residual")
print("coarse distance ~", mp.nstr(mp.sqrt(best[0]), 15), "at t~", best[1])


def chord_cross(n):
    pts = [B(mp.mpf(k) / n) for k in range(n + 1)]
    out = []
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if (y0 + 148) == 0:
            out.append(x0)
        elif (y0 + 148) * (y1 + 148) < 0:
            s = (mp.mpf(-148) - y0) / (y1 - y0)
            out.append(x0 + s * (x1 - x0))
    return out


for n in [8, 16, 32, 48, 64, 96, 128, 256, 512, 1024]:
    print(f" chord n={n}: crossings x={[mp.nstr(v, 12) for v in chord_cross(n)]}")

for t in roots:
    h = mp.mpf("1e-20")
    dx = (B(t + h)[0] - B(t - h)[0]) / (2 * h)
    dy = (B(t + h)[1] - B(t - h)[1]) / (2 * h)
    print(f" t={mp.nstr(t, 8)} dX/dt={mp.nstr(dx, 10)} dY/dt={mp.nstr(dy, 10)} dx/dy={mp.nstr(dx / dy, 10)}")
