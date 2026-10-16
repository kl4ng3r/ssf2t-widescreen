// newpixie CRT (Mattias Gustavsson, MIT / public domain; slang version by hunterk), ported to Metal.
// Same 4 passes as libretro's crt/newpixie-crt.slangp: accumulate -> blur_horiz -> blur_vert -> newpixie-crt.
// Parameters as in the slang shader, except curvature 0.5 (user setting; slang default 2.0).
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

// full-screen triangle strip; uv (0,0) = top-left, like RetroArch's TexCoord
vertex VOut np_vertex(uint vid [[vertex_id]])
{
	float2 p = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
	VOut o; o.pos = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0); o.uv = p; return o;
}

struct NPParams {
	float2 outSize;      // output size of the pass in pixels
	float frameCount;
	float curvature;     // 0.5
	float wiggle;        // 0
	float scanroll;      // 1
	float vignette;      // 1
	float ghosting;      // 1
	float accModulate;   // 0.65
	float blurX;         // 1
	float blurY;         // 1
	float pad;
};

static inline float  gmod(float x, float y)   { return x - y * floor(x / y); }   // GLSL mod
static inline float2 gmod(float2 x, float y)  { return x - y * floor(x / y); }

// pass 1: phosphor persistence
fragment float4 np_accumulate(VOut in [[stage_in]], texture2d<float> prev [[texture(0)]], texture2d<float> src [[texture(1)]],
                              sampler s [[sampler(0)]], constant NPParams &p [[buffer(0)]])
{
	float4 a = prev.sample(s, in.uv) * p.accModulate;
	float4 b = src.sample(s, in.uv);
	return max(a, b * 0.96);
}

static float4 blur9(texture2d<float> t, sampler s, float2 uv, float2 d)
{
	float4 sum = t.sample(s, uv) * 0.2270270270;
	sum += t.sample(s, uv - 4.0 * d) * 0.0162162162;
	sum += t.sample(s, uv - 3.0 * d) * 0.0540540541;
	sum += t.sample(s, uv - 2.0 * d) * 0.1216216216;
	sum += t.sample(s, uv - 1.0 * d) * 0.1945945946;
	sum += t.sample(s, uv + 1.0 * d) * 0.1945945946;
	sum += t.sample(s, uv + 2.0 * d) * 0.1216216216;
	sum += t.sample(s, uv + 3.0 * d) * 0.0540540541;
	sum += t.sample(s, uv + 4.0 * d) * 0.0162162162;
	return sum;
}
fragment float4 np_blur_h(VOut in [[stage_in]], texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]], constant NPParams &p [[buffer(0)]])
{
	return blur9(src, s, in.uv, float2(p.blurX / p.outSize.x, 0.0));
}
fragment float4 np_blur_v(VOut in [[stage_in]], texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]], constant NPParams &p [[buffer(0)]])
{
	return blur9(src, s, in.uv, float2(0.0, p.blurY / p.outSize.y));
}

// final pass
static float3 tsample(texture2d<float> t, sampler s, float2 tc)
{
	tc = tc * float2(1.025, 0.92) + float2(-0.0125, 0.04);
	float3 c = pow(abs(t.sample(s, float2(tc.x, 1.0 - tc.y)).rgb), float3(2.2));
	return c * 1.25;
}
static float3 filmic(float3 c)
{
	float3 x = max(float3(0.0), c - 0.004);
	return (x * (6.2 * x + 0.5)) / (x * (6.2 * x + 1.7) + 0.06);
}
static float2 curve(float2 uv, float curvature)
{
	uv = uv - 0.5;
	uv *= float2(0.925, 1.095);
	uv *= curvature;
	uv.x *= 1.0 + pow(abs(uv.y) / 4.0, 2.0);
	uv.y *= 1.0 + pow(abs(uv.x) / 3.0, 2.0);
	uv /= curvature;
	uv += 0.5;
	uv = uv * 0.92 + 0.04;
	return uv;
}
static float rand2(float2 co) { return fract(sin(dot(co, float2(12.9898, 78.233))) * 43758.5453); }

fragment float4 np_crt(VOut in [[stage_in]], texture2d<float> accum [[texture(0)]], texture2d<float> blur [[texture(1)]],
                       sampler s [[sampler(0)]], constant NPParams &p [[buffer(0)]])
{
	const float2 resolution = p.outSize;
	float2 vTexCoord = float2(in.uv.x, 1.0 - in.uv.y);
	float2 fragCoord = vTexCoord * resolution;
	float time = gmod(p.frameCount, 849.0) * 36.0;
	float2 uv = vTexCoord;
	float2 curved_uv = mix(curve(uv, p.curvature), uv, 0.4);
	float scale = -0.101;
	float2 scuv = curved_uv * (1.0 - scale) + scale / 2.0 + float2(0.003, -0.001);
	uv = scuv;

	float3 col;
	float x = p.wiggle * sin(0.1 * time + curved_uv.y * 13.0) * sin(0.23 * time + curved_uv.y * 19.0) * sin(0.3 + 0.11 * time + curved_uv.y * 23.0) * 0.0012;
	float o = sin(fragCoord.y * 1.5) / resolution.x;
	x += o * 0.25;
	time = gmod(p.frameCount, 640.0);
	col.r = tsample(accum, s, float2(x + scuv.x + 0.0009, scuv.y + 0.0009)).x + 0.02;
	col.g = tsample(accum, s, float2(x + scuv.x + 0.0000, scuv.y - 0.0011)).y + 0.02;
	col.b = tsample(accum, s, float2(x + scuv.x - 0.0015, scuv.y + 0.0000)).z + 0.02;
	float i = clamp(col.r * 0.299 + col.g * 0.587 + col.b * 0.114, 0.0, 1.0);
	i = pow(1.0 - pow(i, 2.0), 1.0);
	i = (1.0 - i) * 0.85 + 0.15;

	// ghosting
	float ghs = 0.15 * p.ghosting;
	float3 r = tsample(blur, s, float2(x - 0.014, -0.027) * 0.85 + 0.007 * float2(0.35 * sin(1.0 / 7.0 + 15.0 * curved_uv.y + 0.9 * time),
	           0.35 * sin(2.0 / 7.0 + 10.0 * curved_uv.y + 1.37 * time)) + float2(scuv.x + 0.001, scuv.y + 0.001)) * float3(0.5, 0.25, 0.25);
	float3 g = tsample(blur, s, float2(x - 0.019, -0.020) * 0.85 + 0.007 * float2(0.35 * cos(1.0 / 9.0 + 15.0 * curved_uv.y + 0.5 * time),
	           0.35 * sin(2.0 / 9.0 + 10.0 * curved_uv.y + 1.50 * time)) + float2(scuv.x + 0.000, scuv.y - 0.002)) * float3(0.25, 0.5, 0.25);
	float3 b = tsample(blur, s, float2(x - 0.017, -0.003) * 0.85 + 0.007 * float2(0.35 * sin(2.0 / 3.0 + 15.0 * curved_uv.y + 0.7 * time),
	           0.35 * cos(2.0 / 3.0 + 10.0 * curved_uv.y + 1.63 * time)) + float2(scuv.x - 0.002, scuv.y + 0.000)) * float3(0.25, 0.25, 0.5);
	col += float3(ghs * (1.0 - 0.299)) * pow(clamp(3.0 * r, 0.0, 1.0), float3(2.0)) * i;
	col += float3(ghs * (1.0 - 0.587)) * pow(clamp(3.0 * g, 0.0, 1.0), float3(2.0)) * i;
	col += float3(ghs * (1.0 - 0.114)) * pow(clamp(3.0 * b, 0.0, 1.0), float3(2.0)) * i;

	// level adjustment
	col *= float3(0.95, 1.05, 0.95);
	col = clamp(col * 1.3 + 0.75 * col * col + 1.25 * col * col * col * col * col, float3(0.0), float3(10.0));

	// vignette
	float vig = (1.0 - 0.99 * p.vignette) + 16.0 * curved_uv.x * curved_uv.y * (1.0 - curved_uv.x) * (1.0 - curved_uv.y);
	vig = 1.3 * pow(max(vig, 0.0), 0.5);
	col *= vig;

	time *= p.scanroll;

	// scanlines
	float scans = clamp(0.35 + 0.18 * sin(6.0 * time - curved_uv.y * resolution.y * 1.5), 0.0, 1.0);
	col *= pow(scans, 0.9);

	// vertical lines (shadow mask)
	col *= 1.0 - 0.23 * clamp(gmod(fragCoord.x, 3.0) / 2.0, 0.0, 1.0);

	col = filmic(col);

	// noise
	float2 seed = curved_uv * resolution;
	col -= 0.015 * pow(float3(rand2(seed + time), rand2(seed + time * 2.0), rand2(seed + time * 3.0)), float3(1.5));

	// flicker
	col *= 1.0 - 0.004 * (sin(50.0 * time + curved_uv.y * 2.0) * 0.5 + 0.5);

	return float4(col, 1.0);
}
