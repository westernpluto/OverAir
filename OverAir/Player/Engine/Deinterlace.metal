#include <metal_stdlib>
using namespace metal;

// Motion-adaptive, edge-directed deinterlacer for interlaced broadcast video (1080i / 480i).
// Each input frame produces one output frame per field. Lines of the kept field are copied;
// missing lines are woven from the other field where nothing moves, and edge-interpolated where it does.

struct DeinterlaceParams {
    uint parity;   // 0 = keep even (top-field) lines, 1 = keep odd (bottom-field) lines
    float lowMotion;
    float highMotion;
};

template <typename T>
static inline T ela(texture2d<float, access::read> cur, int x, int y, int w, int h) {
    int ya = max(y - 1, 0), yb = min(y + 1, h - 1);
    int xl = max(x - 1, 0), xr = min(x + 1, w - 1);
    T a0 = T(cur.read(uint2(xl, ya)).xy), a1 = T(cur.read(uint2(x, ya)).xy), a2 = T(cur.read(uint2(xr, ya)).xy);
    T b0 = T(cur.read(uint2(xl, yb)).xy), b1 = T(cur.read(uint2(x, yb)).xy), b2 = T(cur.read(uint2(xr, yb)).xy);
    float dv = length(float2(a1 - b1));
    float d1 = length(float2(a0 - b2));
    float d2 = length(float2(a2 - b0));
    T v = (a1 + b1) * 0.5;
    if (d1 < dv && d1 <= d2) v = (a0 + b2) * 0.5;
    else if (d2 < dv) v = (a2 + b0) * 0.5;
    return v;
}

kernel void deinterlacePlane(texture2d<float, access::read> cur [[texture(0)]],
                             texture2d<float, access::read> prev [[texture(1)]],
                             texture2d<float, access::write> out [[texture(2)]],
                             constant DeinterlaceParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int w = int(out.get_width()), h = int(out.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    float4 c = cur.read(gid);
    if ((gid.y & 1) == p.parity) {
        out.write(c, gid);
        return;
    }
    int x = int(gid.x), y = int(gid.y);
    float2 spatial = ela<float2>(cur, x, y, w, h);
    float2 weave = c.xy;
    float2 old = prev.read(gid).xy;
    int ya = max(y - 1, 0), yb = min(y + 1, h - 1);
    float2 above = cur.read(uint2(x, ya)).xy, below = cur.read(uint2(x, yb)).xy;
    // Motion: temporal change of the woven line, plus combing against its neighbours.
    float temporal = length(weave - old);
    float combing = max(0.0, min(length(weave - above), length(weave - below)) - length(above - below) * 0.5);
    float motion = max(temporal, combing);
    float a = smoothstep(p.lowMotion, p.highMotion, motion);
    float2 v = mix(weave, spatial, a);
    out.write(float4(v, 0, 1), gid);
}
