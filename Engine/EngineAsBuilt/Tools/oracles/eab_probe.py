import struct, sys, pathlib


class R:
    def __init__(self, b, off=0):
        self.b = b
        self.p = off

    def u8(self):
        v = self.b[self.p]
        self.p += 1
        return v

    def u16(self):
        v = struct.unpack_from("<H", self.b, self.p)[0]
        self.p += 2
        return v

    def u32(self):
        v = struct.unpack_from("<I", self.b, self.p)[0]
        self.p += 4
        return v

    def i32(self):
        v = struct.unpack_from("<i", self.b, self.p)[0]
        self.p += 4
        return v

    def u64(self):
        v = struct.unpack_from("<Q", self.b, self.p)[0]
        self.p += 8
        return v

    def f64(self):
        v = struct.unpack_from("<d", self.b, self.p)[0]
        self.p += 8
        return v

    def vec(self):
        return (self.f64(), self.f64(), self.f64())

    def s(self):
        n = self.u16()
        if n == 0xFFFF:
            n = self.u32()
        v = self.b[self.p:self.p + n].decode("utf-8", "replace")
        self.p += n
        return v

    def uuid(self):
        v = self.b[self.p:self.p + 16].hex()
        self.p += 16
        return v


def color(r, ver):
    if ver < 2:
        return None
    if r.u8() != 0:
        return tuple(r.u8() for _ in range(4))
    return None


def prims(r, ver):
    n = r.u32()
    out = []
    for _ in range(n):
        t = r.u8()
        if t == 1:
            a = r.vec()
            b = r.vec()
            out.append(("line", a, b, color(r, ver)))
        elif t == 11:
            cp = [r.vec() for _ in range(r.u32())]
            kn = [r.f64() for _ in range(r.u32())]
            deg = r.u32()
            hw = r.u8() != 0
            w = [r.f64() for _ in range(len(cp))] if hw else None
            out.append(("spline", cp, kn, deg, w, color(r, ver)))
        elif t == 5:
            cen = r.vec()
            rad = r.f64()
            out.append(("circle", cen, rad, color(r, ver)))
        elif t == 6:
            cen = r.vec()
            rad = r.f64()
            sa = r.f64()
            ea = r.f64()
            out.append(("arc", cen, rad, sa, ea, color(r, ver)))
        elif t == 18:
            closed = r.u8()
            ltg = r.u8()
            vs = [(r.vec(), r.f64(), r.f64(), r.f64()) for _ in range(r.u32())]
            # Hatch metadata for EAB >= 11: carrier, loop type, handle table, and edges.
            if ver >= 11:
                r.u8()
                if ver >= 12:
                    r.i32()
                if ver >= 16:
                    for _ in range(r.u32()):
                        r.u32()
                ec = r.u32()
                assert ec == 0, f"unhandled hatch edges {ec}"
            out.append(("polyline18", closed, vs, color(r, ver)))
        else:
            raise SystemExit(f"unhandled prim type {t} at {r.p - 1:#x}")
    return out


def load(path):
    b = pathlib.Path(path).read_bytes()
    r = R(b)
    magic = r.u32()
    ver = r.u32()
    vc = r.u32()
    diroff = r.u64()
    print(f"{path} magic={magic:#x} ver={ver} views={vc} dirOff={diroff} size={len(b)}")
    d = R(b, diroff)
    name = d.s()
    kind = d.u8()
    cam = [d.f64() for _ in range(4)]
    off = d.u64()
    sz = d.u64()
    print(f" view {name!r} kind={kind} cam(offX,offY,zoom,rot)={cam} dataOff={off} dataSize={sz}")
    vd = b[off:off + sz]
    h = R(vd)
    hm = h.u32()
    hv = h.u32()
    h.u32()
    unit = h.u8()
    h.u8()
    h.u8()
    h.u8()
    toff = h.u64()
    crc = h.u32()
    h.u32()
    print(f" V6 magic={hm:#x} ver={hv} unit={unit} tableOff={toff}")
    t = R(vd, toff)
    secn = t.u32()
    secs = []
    for _ in range(secn):
        ty = t.u32()
        so = t.u64()
        ss = t.u64()
        comp = t.u8()
        t.u8()
        t.u8()
        t.u8()
        secs.append((ty, so, ss, comp))
        print(f"  section type={ty} off={so} size={ss} comp={comp}")
    for ty, so, ss, comp in secs:
        if ty != 3:
            continue
        e = R(vd, so)
        n = e.u32()
        print(f" entities={n}")
        for i in range(n):
            handle = e.uuid()
            layer = e.uuid()
            block = e.uuid()
            tf = [e.f64() for _ in range(16)]
            flags = e.u8()
            bbox = [struct.unpack_from("<f", e.b, e.p + 4 * j)[0] for j in range(6)]
            e.p += 24
            has_lg = bool(flags & 2)
            pva = None
            if has_lg:
                pva = (e.u32(), e.u32(), e.u32())
            ps = prims(e, hv) if has_lg else []
            print(f"  [{i}] handle={handle[:8]} flags={flags:#x} bbox={bbox} pva={pva}")
            print(f"      transform={tf}")
            for p in ps:
                print(f"      {p}")
            if flags & 1:
                raise SystemExit("xdata unhandled")
            if flags & 4:
                print(f"      drawOrder={e.i32()}")
            assert not (flags & 0x78), f"unhandled flags {flags:#x}"
    print()


for p in sys.argv[1:]:
    load(p)
