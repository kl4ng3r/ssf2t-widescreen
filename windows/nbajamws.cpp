// NBA Jam TE Rewind Widescreen for Windows: a small libretro frontend around the statically linked
// FinalBurn Neo core (nbajamrw driver). SDL2 for window / input / audio, OpenGL 3.3 for video and
// the newpixie CRT filter (same 4 passes and settings as the iOS app's Metal version).
//
// Controls: see README. Esc = menu, F2 = save state, F4 = load state, F3 = CRT filter,
// F11 or Alt+Enter = fullscreen. Up to 4 game controllers (players 1-4).
#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <string>
#include <vector>
#include <atomic>
#include "libretro.h"
#include "font.h"
#include "romcheck.h"

#ifdef _WIN32
#include <direct.h>
#define MKDIR(p) _mkdir(p)
#else
#include <sys/stat.h>
#define MKDIR(p) mkdir(p, 0755)
#endif

extern "C" void nbajamrw_save_nvram(void);

// ------------------------------------------------------------------ OpenGL 3.3 (loaded via SDL)
typedef unsigned int GLenum; typedef unsigned int GLuint; typedef int GLint; typedef int GLsizei;
typedef float GLfloat; typedef char GLchar; typedef unsigned char GLboolean; typedef unsigned int GLbitfield;
typedef ptrdiff_t GLsizeiptr; typedef void GLvoid;
#ifdef _WIN32
#define GLAPI __stdcall
#else
#define GLAPI
#endif
#define GL_TEXTURE_2D 0x0DE1
#define GL_TEXTURE0 0x84C0
#define GL_TEXTURE1 0x84C1
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_WRAP_S 0x2802
#define GL_TEXTURE_WRAP_T 0x2803
#define GL_CLAMP_TO_BORDER 0x812D
#define GL_CLAMP_TO_EDGE 0x812F
#define GL_LINEAR 0x2601
#define GL_RGBA 0x1908
#define GL_BGRA 0x80E1
#define GL_RED 0x1903
#define GL_R8 0x8229
#define GL_RGBA8 0x8058
#define GL_RGBA16F 0x881A
#define GL_UNSIGNED_BYTE 0x1401
#define GL_FLOAT 0x1406
#define GL_HALF_FLOAT 0x140B
#define GL_FRAMEBUFFER 0x8D40
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_VERTEX_SHADER 0x8B31
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_ARRAY_BUFFER 0x8892
#define GL_DYNAMIC_DRAW 0x88E8
#define GL_TRIANGLE_STRIP 0x0005
#define GL_TRIANGLES 0x0004
#define GL_COLOR_BUFFER_BIT 0x4000
#define GL_BLEND 0x0BE2
#define GL_SRC_ALPHA 0x0302
#define GL_ONE_MINUS_SRC_ALPHA 0x0303
#define GL_UNPACK_ALIGNMENT 0x0CF5
#define GL_UNPACK_ROW_LENGTH 0x0CF2
#define GL_PACK_ALIGNMENT 0x0D05

#define GLFUNCS \
	F(void, glClear, GLbitfield) F(void, glClearColor, GLfloat, GLfloat, GLfloat, GLfloat) \
	F(void, glViewport, GLint, GLint, GLsizei, GLsizei) F(void, glEnable, GLenum) F(void, glDisable, GLenum) \
	F(void, glBlendFunc, GLenum, GLenum) F(void, glPixelStorei, GLenum, GLint) \
	F(void, glGenTextures, GLsizei, GLuint *) F(void, glDeleteTextures, GLsizei, const GLuint *) \
	F(void, glBindTexture, GLenum, GLuint) F(void, glActiveTexture, GLenum) \
	F(void, glTexImage2D, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *) \
	F(void, glTexSubImage2D, GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *) \
	F(void, glTexParameteri, GLenum, GLenum, GLint) \
	F(void, glReadPixels, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *) \
	F(GLuint, glCreateShader, GLenum) F(void, glShaderSource, GLuint, GLsizei, const GLchar *const *, const GLint *) \
	F(void, glCompileShader, GLuint) F(void, glGetShaderiv, GLuint, GLenum, GLint *) \
	F(void, glGetShaderInfoLog, GLuint, GLsizei, GLsizei *, GLchar *) F(GLuint, glCreateProgram, void) \
	F(void, glAttachShader, GLuint, GLuint) F(void, glLinkProgram, GLuint) F(void, glGetProgramiv, GLuint, GLenum, GLint *) \
	F(void, glGetProgramInfoLog, GLuint, GLsizei, GLsizei *, GLchar *) F(void, glUseProgram, GLuint) \
	F(void, glBindAttribLocation, GLuint, GLuint, const GLchar *) \
	F(GLint, glGetUniformLocation, GLuint, const GLchar *) F(void, glUniform1i, GLint, GLint) \
	F(void, glUniform1f, GLint, GLfloat) F(void, glUniform2f, GLint, GLfloat, GLfloat) \
	F(void, glUniform4f, GLint, GLfloat, GLfloat, GLfloat, GLfloat) \
	F(void, glGenFramebuffers, GLsizei, GLuint *) F(void, glBindFramebuffer, GLenum, GLuint) \
	F(void, glFramebufferTexture2D, GLenum, GLenum, GLenum, GLuint, GLint) \
	F(void, glGenVertexArrays, GLsizei, GLuint *) F(void, glBindVertexArray, GLuint) \
	F(void, glGenBuffers, GLsizei, GLuint *) F(void, glBindBuffer, GLenum, GLuint) \
	F(void, glBufferData, GLenum, GLsizeiptr, const void *, GLenum) \
	F(void, glVertexAttribPointer, GLuint, GLint, GLenum, GLboolean, GLsizei, const void *) \
	F(void, glEnableVertexAttribArray, GLuint) F(void, glDrawArrays, GLenum, GLint, GLsizei)

#define F(ret, name, ...) typedef ret (GLAPI *PFN_##name)(__VA_ARGS__); static PFN_##name name;
GLFUNCS
#undef F

static bool gl_load()
{
	bool ok = true;
#define F(ret, name, ...) name = (PFN_##name)SDL_GL_GetProcAddress(#name); if (!name) { SDL_Log("missing %s", #name); ok = false; }
	GLFUNCS
#undef F
	return ok;
}

// ------------------------------------------------------------------ paths & settings
static std::string g_base;                 // folder of the exe (ROM, saves)
static std::string g_saveDir;              // <base>/saves (libretro system + save dir)
static bool g_crtOn = false, g_fullscreen = false;

static std::string settings_path() { return g_saveDir + "/settings.ini"; }
static void load_settings()
{
	FILE *f = fopen(settings_path().c_str(), "r"); if (!f) return;
	char line[128];
	while (fgets(line, sizeof line, f)) {
		int v;
		if (sscanf(line, "crt=%d", &v) == 1) g_crtOn = v != 0;
		if (sscanf(line, "fullscreen=%d", &v) == 1) g_fullscreen = v != 0;
	}
	fclose(f);
}
static void save_settings()
{
	FILE *f = fopen(settings_path().c_str(), "w"); if (!f) return;
	fprintf(f, "crt=%d\nfullscreen=%d\n", g_crtOn ? 1 : 0, g_fullscreen ? 1 : 0);
	fclose(f);
}
static bool file_exists(const std::string &p) { FILE *f = fopen(p.c_str(), "rb"); if (f) fclose(f); return f != NULL; }
static bool copy_file(const std::string &from, const std::string &to)
{
	FILE *a = fopen(from.c_str(), "rb"); if (!a) return false;
	FILE *b = fopen(to.c_str(), "wb"); if (!b) { fclose(a); return false; }
	char buf[65536]; size_t n; bool ok = true;
	while ((n = fread(buf, 1, sizeof buf, a)) > 0) if (fwrite(buf, 1, n, b) != n) { ok = false; break; }
	fclose(a); if (fclose(b) != 0) ok = false;
	return ok;
}

// ------------------------------------------------------------------ libretro glue
#define PORTS 4
static enum retro_pixel_format g_fmt = RETRO_PIXEL_FORMAT_0RGB1555;
static std::vector<uint32_t> g_frame; static unsigned g_fw, g_fh; static bool g_newFrame;
static uint16_t g_pad[PORTS];
static float g_aspect = 128.0f / 75.0f;
static bool g_loaded;
static double g_fps = 54.71, g_rate = 48000;

#define RING 16384
static int16_t g_ring[RING * 2];
static std::atomic<uint32_t> g_rw(0), g_rr(0);
static double g_ratio = 1.0, g_pos = 0.0;
static int16_t g_last[2];

static void core_log(enum retro_log_level, const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
}
static bool core_env(unsigned cmd, void *data)
{
	switch (cmd) {
	case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: g_fmt = *(enum retro_pixel_format *)data; return true;
	case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
	case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: *(const char **)data = g_saveDir.c_str(); return true;
	case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: ((struct retro_log_callback *)data)->log = core_log; return true;
	case RETRO_ENVIRONMENT_GET_CAN_DUPE: *(bool *)data = true; return true;
	case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: return true;
	case RETRO_ENVIRONMENT_SET_GEOMETRY: {
		const struct retro_game_geometry *g = (const struct retro_game_geometry *)data;
		if (g->aspect_ratio > 0) g_aspect = g->aspect_ratio;
		return true;
	}
	case RETRO_ENVIRONMENT_GET_VARIABLE: {       // only option we set: the test-menu button combo
		struct retro_variable *v = (struct retro_variable *)data;
		if (v && v->key && !strcmp(v->key, "fbneo-diagnostic-input")) { v->value = "Start + L + R"; return true; }
		return false;
	}
	default: return false;
	}
}
static void core_video(const void *data, unsigned w, unsigned h, size_t pitch)
{
	if (!data) return;
	if (w != g_fw || h != g_fh) { g_frame.assign(w * h, 0); g_fw = w; g_fh = h; }
	for (unsigned y = 0; y < h; y++) {
		const uint8_t *src = (const uint8_t *)data + y * pitch; uint32_t *dst = &g_frame[y * w];
		if (g_fmt == RETRO_PIXEL_FORMAT_XRGB8888) memcpy(dst, src, w * 4);
		else if (g_fmt == RETRO_PIXEL_FORMAT_RGB565) {
			const uint16_t *s = (const uint16_t *)src;
			for (unsigned x = 0; x < w; x++) { uint16_t p = s[x];
				dst[x] = ((p >> 11) << 19) | (((p >> 5) & 63) << 10) | ((p & 31) << 3); }
		} else {
			const uint16_t *s = (const uint16_t *)src;
			for (unsigned x = 0; x < w; x++) { uint16_t p = s[x];
				dst[x] = (((p >> 10) & 31) << 19) | (((p >> 5) & 31) << 11) | ((p & 31) << 3); }
		}
	}
	g_newFrame = true;
}
// Emulated frames are paced to the arcade's 54.71 Hz by the main loop; the audio is resampled by
// g_ratio (output/input frames), nudged by up to 0.5 % to keep the buffer level steady.
static size_t core_audio_batch(const int16_t *d, size_t frames)
{
	uint32_t w = g_rw.load(), r = g_rr.load();
	const double step = 1.0 / g_ratio;
	for (size_t i = 0; i < frames; ) {
		while (g_pos < 1.0) {
			if (w - r >= RING) { g_pos += step; continue; }
			double t = g_pos;
			for (int c = 0; c < 2; c++)
				g_ring[(w & (RING - 1)) * 2 + c] = (int16_t)(g_last[c] + (d[i * 2 + c] - g_last[c]) * t);
			w++; g_pos += step;
		}
		g_pos -= 1.0;
		g_last[0] = d[i * 2]; g_last[1] = d[i * 2 + 1];
		i++;
	}
	g_rw.store(w);
	return frames;
}
static void core_audio(int16_t l, int16_t r) { int16_t s[2] = { l, r }; core_audio_batch(s, 1); }
static void core_poll(void) {}
static int16_t core_input(unsigned port, unsigned dev, unsigned, unsigned id)
{
	if (port >= PORTS || (dev & RETRO_DEVICE_MASK) != RETRO_DEVICE_JOYPAD) return 0;
	if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)g_pad[port];
	return (g_pad[port] >> id) & 1;
}
static void SDLCALL audio_cb(void *, Uint8 *stream, int len)
{
	int16_t *out = (int16_t *)stream; int n = len / 4;
	uint32_t r = g_rr.load(), w = g_rw.load();
	for (int i = 0; i < n; i++) {
		if (r != w) { out[i * 2] = g_ring[(r & (RING - 1)) * 2]; out[i * 2 + 1] = g_ring[(r & (RING - 1)) * 2 + 1]; r++; }
		else { out[i * 2] = 0; out[i * 2 + 1] = 0; }
	}
	g_rr.store(r);
}

// ------------------------------------------------------------------ shaders
static const char *VS =
	"#version 330 core\n"
	"uniform vec4 rect; uniform float flipY; uniform vec4 uvRect;\n"   // rect in NDC: x0 y0 x1 y1; uvRect: u v w h
	"out vec2 uv;\n"
	"void main() {\n"
	"  vec2 p = vec2((gl_VertexID & 1) != 0 ? 1.0 : 0.0, (gl_VertexID & 2) != 0 ? 1.0 : 0.0);\n"
	"  uv = uvRect.xy + p * uvRect.zw;\n"                      // uv (0,0) = top-left, like the Metal version
	"  float y = flipY > 0.5 ? mix(rect.w, rect.y, p.y) : mix(rect.y, rect.w, p.y);\n"
	"  gl_Position = vec4(mix(rect.x, rect.z, p.x), y, 0.0, 1.0);\n"
	"}\n";

static const char *FS_HEAD =
	"#version 330 core\n"
	"in vec2 uv; out vec4 frag;\n"
	"uniform sampler2D tex0; uniform sampler2D tex1;\n"
	"uniform vec2 outSize; uniform float frameCount, curvature, wiggle, scanroll, vignette, ghosting, accModulate, blurX, blurY;\n"
	"uniform vec4 color;\n";

static const char *FS_COPY = "void main() { frag = vec4(texture(tex0, uv).rgb, 1.0); }\n";
static const char *FS_TEXT = "void main() { frag = vec4(color.rgb, color.a * texture(tex0, uv).r); }\n";
static const char *FS_FILL = "void main() { frag = color; }\n";

// newpixie CRT (Mattias Gustavsson, MIT / public domain; slang version by hunterk)
static const char *FS_ACC =
	"void main() {\n"
	"  vec4 a = texture(tex0, uv) * accModulate;\n"
	"  vec4 b = texture(tex1, uv);\n"
	"  frag = max(a, b * 0.96);\n"
	"}\n";
static const char *FS_BLUR =
	"uniform vec2 dir;\n"
	"void main() {\n"
	"  vec2 d = dir / outSize;\n"
	"  vec4 sum = texture(tex0, uv) * 0.2270270270;\n"
	"  sum += texture(tex0, uv - 4.0 * d) * 0.0162162162;\n"
	"  sum += texture(tex0, uv - 3.0 * d) * 0.0540540541;\n"
	"  sum += texture(tex0, uv - 2.0 * d) * 0.1216216216;\n"
	"  sum += texture(tex0, uv - 1.0 * d) * 0.1945945946;\n"
	"  sum += texture(tex0, uv + 1.0 * d) * 0.1945945946;\n"
	"  sum += texture(tex0, uv + 2.0 * d) * 0.1216216216;\n"
	"  sum += texture(tex0, uv + 3.0 * d) * 0.0540540541;\n"
	"  sum += texture(tex0, uv + 4.0 * d) * 0.0162162162;\n"
	"  frag = sum;\n"
	"}\n";
static const char *FS_CRT =
	"float gmod(float x, float y) { return x - y * floor(x / y); }\n"
	"vec3 tsample(sampler2D t, vec2 tc) {\n"
	"  tc = tc * vec2(1.025, 0.92) + vec2(-0.0125, 0.04);\n"
	"  vec3 c = pow(abs(texture(t, vec2(tc.x, 1.0 - tc.y)).rgb), vec3(2.2));\n"
	"  return c * 1.25;\n"
	"}\n"
	"vec3 filmic(vec3 c) { vec3 x = max(vec3(0.0), c - 0.004); return (x * (6.2 * x + 0.5)) / (x * (6.2 * x + 1.7) + 0.06); }\n"
	"vec2 curve(vec2 uv, float k) {\n"
	"  uv = uv - 0.5; uv *= vec2(0.925, 1.095); uv *= k;\n"
	"  uv.x *= 1.0 + pow(abs(uv.y) / 4.0, 2.0); uv.y *= 1.0 + pow(abs(uv.x) / 3.0, 2.0);\n"
	"  uv /= k; uv += 0.5; uv = uv * 0.92 + 0.04; return uv;\n"
	"}\n"
	"float rand2(vec2 co) { return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453); }\n"
	"void main() {\n"
	"  vec2 resolution = outSize;\n"
	"  vec2 vTexCoord = vec2(uv.x, 1.0 - uv.y);\n"
	"  vec2 fragCoord = vTexCoord * resolution;\n"
	"  float time = gmod(frameCount, 849.0) * 36.0;\n"
	"  vec2 cuv = mix(curve(vTexCoord, curvature), vTexCoord, 0.4);\n"
	"  float scale = -0.101;\n"
	"  vec2 scuv = cuv * (1.0 - scale) + scale / 2.0 + vec2(0.003, -0.001);\n"
	"  vec3 col;\n"
	"  float x = wiggle * sin(0.1 * time + cuv.y * 13.0) * sin(0.23 * time + cuv.y * 19.0) * sin(0.3 + 0.11 * time + cuv.y * 23.0) * 0.0012;\n"
	"  float o = sin(fragCoord.y * 1.5) / resolution.x;\n"
	"  x += o * 0.25;\n"
	"  time = gmod(frameCount, 640.0);\n"
	"  col.r = tsample(tex0, vec2(x + scuv.x + 0.0009, scuv.y + 0.0009)).x + 0.02;\n"
	"  col.g = tsample(tex0, vec2(x + scuv.x + 0.0000, scuv.y - 0.0011)).y + 0.02;\n"
	"  col.b = tsample(tex0, vec2(x + scuv.x - 0.0015, scuv.y + 0.0000)).z + 0.02;\n"
	"  float i = clamp(col.r * 0.299 + col.g * 0.587 + col.b * 0.114, 0.0, 1.0);\n"
	"  i = pow(1.0 - pow(i, 2.0), 1.0);\n"
	"  i = (1.0 - i) * 0.85 + 0.15;\n"
	"  float ghs = 0.15 * ghosting;\n"
	"  vec3 r = tsample(tex1, vec2(x - 0.014, -0.027) * 0.85 + 0.007 * vec2(0.35 * sin(1.0 / 7.0 + 15.0 * cuv.y + 0.9 * time),\n"
	"           0.35 * sin(2.0 / 7.0 + 10.0 * cuv.y + 1.37 * time)) + vec2(scuv.x + 0.001, scuv.y + 0.001)) * vec3(0.5, 0.25, 0.25);\n"
	"  vec3 g = tsample(tex1, vec2(x - 0.019, -0.020) * 0.85 + 0.007 * vec2(0.35 * cos(1.0 / 9.0 + 15.0 * cuv.y + 0.5 * time),\n"
	"           0.35 * sin(2.0 / 9.0 + 10.0 * cuv.y + 1.50 * time)) + vec2(scuv.x + 0.000, scuv.y - 0.002)) * vec3(0.25, 0.5, 0.25);\n"
	"  vec3 b = tsample(tex1, vec2(x - 0.017, -0.003) * 0.85 + 0.007 * vec2(0.35 * sin(2.0 / 3.0 + 15.0 * cuv.y + 0.7 * time),\n"
	"           0.35 * cos(2.0 / 3.0 + 10.0 * cuv.y + 1.63 * time)) + vec2(scuv.x - 0.002, scuv.y + 0.000)) * vec3(0.25, 0.25, 0.5);\n"
	"  col += vec3(ghs * (1.0 - 0.299)) * pow(clamp(3.0 * r, 0.0, 1.0), vec3(2.0)) * i;\n"
	"  col += vec3(ghs * (1.0 - 0.587)) * pow(clamp(3.0 * g, 0.0, 1.0), vec3(2.0)) * i;\n"
	"  col += vec3(ghs * (1.0 - 0.114)) * pow(clamp(3.0 * b, 0.0, 1.0), vec3(2.0)) * i;\n"
	"  col *= vec3(0.95, 1.05, 0.95);\n"
	"  col = clamp(col * 1.3 + 0.75 * col * col + 1.25 * col * col * col * col * col, vec3(0.0), vec3(10.0));\n"
	"  float vig = (1.0 - 0.99 * vignette) + 16.0 * cuv.x * cuv.y * (1.0 - cuv.x) * (1.0 - cuv.y);\n"
	"  vig = 1.3 * pow(max(vig, 0.0), 0.5);\n"
	"  col *= vig;\n"
	"  time *= scanroll;\n"
	"  float scans = clamp(0.35 + 0.18 * sin(6.0 * time - cuv.y * resolution.y * 1.5), 0.0, 1.0);\n"
	"  col *= pow(scans, 0.9);\n"
	"  col *= 1.0 - 0.23 * clamp(gmod(fragCoord.x, 3.0) / 2.0, 0.0, 1.0);\n"
	"  col = filmic(col);\n"
	"  vec2 seed = cuv * resolution;\n"
	"  col -= 0.015 * pow(vec3(rand2(seed + time), rand2(seed + time * 2.0), rand2(seed + time * 3.0)), vec3(1.5));\n"
	"  col *= 1.0 - 0.004 * (sin(50.0 * time + cuv.y * 2.0) * 0.5 + 0.5);\n"
	"  frag = vec4(col, 1.0);\n"
	"}\n";

struct Prog { GLuint id = 0; };
static GLuint compile(GLenum type, const char *a, const char *b)
{
	GLuint s = glCreateShader(type);
	const char *src[2] = { a, b ? b : "" };
	glShaderSource(s, 2, src, NULL); glCompileShader(s);
	GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) { char log[2048]; glGetShaderInfoLog(s, sizeof log, NULL, log); SDL_Log("shader: %s", log); }
	return s;
}
static GLuint program(const char *fs)
{
	GLuint p = glCreateProgram();
	glAttachShader(p, compile(GL_VERTEX_SHADER, VS, NULL));
	glAttachShader(p, compile(GL_FRAGMENT_SHADER, FS_HEAD, fs));
	glLinkProgram(p);
	GLint ok = 0; glGetProgramiv(p, GL_LINK_STATUS, &ok);
	if (!ok) { char log[2048]; glGetProgramInfoLog(p, sizeof log, NULL, log); SDL_Log("link: %s", log); return 0; }
	glUseProgram(p);
	glUniform1i(glGetUniformLocation(p, "tex0"), 0);
	glUniform1i(glGetUniformLocation(p, "tex1"), 1);
	return p;
}

// ------------------------------------------------------------------ renderer
static SDL_Window *g_win; static int g_W, g_H;
static GLuint g_vao, pCopy, pText, pFill, pAcc, pBlur, pCrt;
static GLuint tSrc, tFont, tAcc[2], tBlur1, tBlur2, fbAcc[2], fbBlur1, fbBlur2;
static int g_accIdx; static unsigned g_texW, g_texH; static uint32_t g_crtFrame;
static bool g_accValid;

static GLuint make_tex(GLint ifmt, int w, int h, GLenum fmt, GLenum type, const void *px, bool border)
{
	GLuint t; glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t);
	glTexImage2D(GL_TEXTURE_2D, 0, ifmt, w, h, 0, fmt, type, px);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	GLint wrap = border ? GL_CLAMP_TO_BORDER : GL_CLAMP_TO_EDGE;   // newpixie: clamp to border (black)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrap);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrap);
	return t;
}
static GLuint make_fb(GLuint tex)
{
	GLuint f; glGenFramebuffers(1, &f); glBindFramebuffer(GL_FRAMEBUFFER, f);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	return f;
}
static bool gfx_init()
{
	if (!gl_load()) return false;
	glGenVertexArrays(1, &g_vao); glBindVertexArray(g_vao);
	pCopy = program(FS_COPY); pText = program(FS_TEXT); pFill = program(FS_FILL);
	pAcc = program(FS_ACC); pBlur = program(FS_BLUR); pCrt = program(FS_CRT);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	tFont = make_tex(GL_R8, FONT_W, FONT_H, GL_RED, GL_UNSIGNED_BYTE, font_px, false);
	return pCopy && pText && pFill;
}
static void set_rect(GLuint p, float x0, float y0, float x1, float y1, bool toScreen)
{
	// rect in pixels of the current target (top-left origin) -> NDC
	glUniform4f(glGetUniformLocation(p, "rect"), x0, y0, x1, y1);
	glUniform1f(glGetUniformLocation(p, "flipY"), toScreen ? 1.0f : 0.0f);
	glUniform4f(glGetUniformLocation(p, "uvRect"), 0.0f, 0.0f, 1.0f, 1.0f);
}
static void draw_quad() { glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); }

// pixel rect on the window (top-left origin) -> NDC rect for the vertex shader
static void win_rect(GLuint p, float x, float y, float w, float h)
{
	float x0 = x / g_W * 2 - 1, x1 = (x + w) / g_W * 2 - 1;
	float yt = 1 - y / g_H * 2, yb = 1 - (y + h) / g_H * 2;
	// flipY: uv.y 0 at the top -> top NDC value goes in rect.w
	set_rect(p, x0, yb, x1, yt, true);
}
static void fill(float x, float y, float w, float h, float r, float g, float b, float a)
{
	glUseProgram(pFill); win_rect(pFill, x, y, w, h);
	glUniform4f(glGetUniformLocation(pFill, "color"), r, g, b, a);
	draw_quad();
}
static float text_width(const char *s, float px)
{
	float k = px / FONT_CH, w = 0;
	for (; *s; s++) { int c = (unsigned char)*s - 32; if (c < 0 || c > 94) c = 0; w += font_adv[c] * k; }
	return w;
}
static void text(const char *s, float x, float y, float px, float r, float g, float b, float a)
{
	float k = px / FONT_CH;
	glUseProgram(pText);
	glUniform4f(glGetUniformLocation(pText, "color"), r, g, b, a);
	glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tFont);
	for (; *s; s++) {
		int c = (unsigned char)*s - 32; if (c < 0 || c > 94) c = 0;
		if (c) {
			win_rect(pText, x, y, FONT_CW * k, FONT_CH * k);
			glUniform4f(glGetUniformLocation(pText, "uvRect"), (float)(c % FONT_COLS) * FONT_CW / FONT_W,
			            (float)(c / FONT_COLS) * FONT_CH / FONT_H, (float)FONT_CW / FONT_W, (float)FONT_CH / FONT_H);
			draw_quad();
		}
		x += font_adv[c] * k;
	}
}

// game picture rectangle in the window (keeps the core's aspect ratio)
static void game_rect(float &x, float &y, float &w, float &h)
{
	w = (float)g_W; h = w / g_aspect;
	if (h > g_H) { h = (float)g_H; w = h * g_aspect; }
	x = (g_W - w) / 2; y = (g_H - h) / 2;
}
static void pass(GLuint p, GLuint fb, int w, int h, GLuint t0, GLuint t1)
{
	glBindFramebuffer(GL_FRAMEBUFFER, fb); glViewport(0, 0, w, h);
	glUseProgram(p); set_rect(p, -1, -1, 1, 1, false);
	glUniform2f(glGetUniformLocation(p, "outSize"), (float)w, (float)h);
	glUniform1f(glGetUniformLocation(p, "accModulate"), 0.65f);
	glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, t0);
	glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, t1 ? t1 : t0);
	glActiveTexture(GL_TEXTURE0);
	draw_quad();
}
static void upload_frame()
{
	if (!g_fw) return;
	if (!tSrc || g_texW != g_fw || g_texH != g_fh) {
		if (tSrc) { glDeleteTextures(1, &tSrc); glDeleteTextures(2, tAcc); glDeleteTextures(1, &tBlur1); glDeleteTextures(1, &tBlur2); }
		tSrc = make_tex(GL_RGBA8, g_fw, g_fh, GL_BGRA, GL_UNSIGNED_BYTE, NULL, true);
		for (int i = 0; i < 2; i++) { tAcc[i] = make_tex(GL_RGBA16F, g_fw, g_fh, GL_RGBA, GL_FLOAT, NULL, true); fbAcc[i] = make_fb(tAcc[i]); }
		tBlur1 = make_tex(GL_RGBA16F, g_fw, g_fh, GL_RGBA, GL_FLOAT, NULL, true); fbBlur1 = make_fb(tBlur1);
		tBlur2 = make_tex(GL_RGBA16F, g_fw, g_fh, GL_RGBA, GL_FLOAT, NULL, true); fbBlur2 = make_fb(tBlur2);
		g_texW = g_fw; g_texH = g_fh; g_accValid = false;
	}
	glBindTexture(GL_TEXTURE_2D, tSrc);
	glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, g_fw, g_fh, GL_BGRA, GL_UNSIGNED_BYTE, g_frame.data());
	if (g_crtOn) {
		if (!g_accValid) {               // start the phosphor buffer from black
			for (int i = 0; i < 2; i++) { glBindFramebuffer(GL_FRAMEBUFFER, fbAcc[i]); glClearColor(0, 0, 0, 0); glClear(GL_COLOR_BUFFER_BIT); }
			glBindFramebuffer(GL_FRAMEBUFFER, 0); g_accValid = true;
		}
		GLuint prev = tAcc[g_accIdx]; int a = g_accIdx ^ 1; g_accIdx = a;
		pass(pAcc, fbAcc[a], g_fw, g_fh, prev, tSrc);
		glUseProgram(pBlur); glUniform2f(glGetUniformLocation(pBlur, "dir"), 1.0f, 0.0f);
		pass(pBlur, fbBlur1, g_fw, g_fh, tAcc[a], 0);
		glUseProgram(pBlur); glUniform2f(glGetUniformLocation(pBlur, "dir"), 0.0f, 1.0f);
		pass(pBlur, fbBlur2, g_fw, g_fh, tBlur1, 0);
		glBindFramebuffer(GL_FRAMEBUFFER, 0);
		g_crtFrame++;
	}
}
static void draw_game()
{
	glBindFramebuffer(GL_FRAMEBUFFER, 0); glViewport(0, 0, g_W, g_H);
	glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
	if (!tSrc) return;
	float x, y, w, h; game_rect(x, y, w, h);
	if (g_crtOn) {
		// the CRT pass renders at the window's resolution inside the picture rectangle
		glViewport((int)x, (int)(g_H - y - h), (int)w, (int)h);
		glUseProgram(pCrt); set_rect(pCrt, -1, -1, 1, 1, true);
		glUniform2f(glGetUniformLocation(pCrt, "outSize"), w, h);
		glUniform1f(glGetUniformLocation(pCrt, "frameCount"), (float)g_crtFrame);
		glUniform1f(glGetUniformLocation(pCrt, "curvature"), 0.5f);
		glUniform1f(glGetUniformLocation(pCrt, "wiggle"), 0.0f);
		glUniform1f(glGetUniformLocation(pCrt, "scanroll"), 1.0f);
		glUniform1f(glGetUniformLocation(pCrt, "vignette"), 1.0f);
		glUniform1f(glGetUniformLocation(pCrt, "ghosting"), 1.0f);
		glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tAcc[g_accIdx]);
		glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, tBlur2);
		glActiveTexture(GL_TEXTURE0);
		draw_quad();
		glViewport(0, 0, g_W, g_H);
	} else {
		glUseProgram(pCopy); win_rect(pCopy, x, y, w, h);
		glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tSrc);
		draw_quad();
	}
}

// ------------------------------------------------------------------ UI: top bar + menu
struct Button { const char *label; int id; float x, y, w, h; };
enum { B_COIN, B_START, B_MENU, B_CRT };
static Button g_bar[4] = { { "COIN", B_COIN }, { "START", B_START }, { "MENU", B_MENU }, { "CRT", B_CRT } };
static Uint32 g_barShownAt; static bool g_barVisible = true;
static int g_mouseX = -1, g_mouseY = -1; static int g_mouseDownBtn = -1;
static uint16_t g_clickBits;                       // coin / start held with the mouse

static bool g_menuOpen; static int g_menuSel;
static std::vector<std::string> g_menuItems;
static std::string g_toast; static Uint32 g_toastAt;
static void toast(const std::string &s) { g_toast = s; g_toastAt = SDL_GetTicks(); }

static float ui_scale() { return g_H / 720.0f; }
static void layout_bar()
{
	float s = ui_scale(), px = 20 * s, padx = 14 * s, gap = 12 * s, h = 34 * s;
	float total = 0;
	for (auto &b : g_bar) { b.w = text_width(b.id == B_CRT && g_crtOn ? "CRT ON" : b.label, px) + 2 * padx; b.h = h; total += b.w; }
	total += gap * 3;
	float x = (g_W - total) / 2, y = 8 * s;
	for (auto &b : g_bar) { b.x = x; b.y = y; x += b.w + gap; }
}
static int bar_hit(int mx, int my)
{
	if (!g_barVisible) return -1;
	for (auto &b : g_bar) if (mx >= b.x && mx < b.x + b.w && my >= b.y && my < b.y + b.h) return b.id;
	return -1;
}
static void show_bar() { g_barShownAt = SDL_GetTicks(); g_barVisible = true; }
static void draw_bar()
{
	if (!g_menuOpen && SDL_GetTicks() - g_barShownAt > 5000) g_barVisible = false;
	if (!g_barVisible) return;
	layout_bar();
	float s = ui_scale(), px = 20 * s;
	for (auto &b : g_bar) {
		bool on = b.id == B_CRT && g_crtOn;
		bool hot = bar_hit(g_mouseX, g_mouseY) == b.id;
		if (on) fill(b.x, b.y, b.w, b.h, 0.1f, 0.45f, 0.2f, 0.7f);
		else fill(b.x, b.y, b.w, b.h, hot ? 0.3f : 0.15f, hot ? 0.3f : 0.15f, hot ? 0.3f : 0.15f, 0.55f);
		const char *l = on ? "CRT ON" : b.label;
		text(l, b.x + (b.w - text_width(l, px)) / 2, b.y + (b.h - px) / 2 - 1 * s, px, 1, 1, 1, 0.85f);
	}
}

static void menu_build()
{
	g_menuItems = { "Resume", "Save State", "Load State",
		std::string("CRT Filter: ") + (g_crtOn ? "On" : "Off"),
		std::string("Fullscreen: ") + (g_fullscreen ? "On" : "Off"),
		"Test Menu (difficulty, free play...)", "Reset", "Quit" };
}
static void menu_open() { if (g_menuOpen) return; g_menuOpen = true; g_menuSel = 0; menu_build(); show_bar(); }
static void menu_rect(int i, float &x, float &y, float &w, float &h)
{
	float s = ui_scale(); w = 520 * s; h = 46 * s;
	float total = h * g_menuItems.size() + 70 * s;
	x = (g_W - w) / 2; y = (g_H - total) / 2 + 70 * s + i * h;
}
static int menu_hit(int mx, int my)
{
	for (size_t i = 0; i < g_menuItems.size(); i++) {
		float x, y, w, h; menu_rect((int)i, x, y, w, h);
		if (mx >= x && mx < x + w && my >= y && my < y + h) return (int)i;
	}
	return -1;
}
static void draw_menu()
{
	if (!g_menuOpen) return;
	float s = ui_scale();
	fill(0, 0, (float)g_W, (float)g_H, 0, 0, 0, 0.55f);
	float x, y, w, h; menu_rect(0, x, y, w, h);
	fill(x - 16 * s, y - 70 * s, w + 32 * s, h * g_menuItems.size() + 86 * s, 0.08f, 0.06f, 0.14f, 0.95f);
	const char *title = "NBA Jam TE Widescreen";
	text(title, (g_W - text_width(title, 30 * s)) / 2, y - 56 * s, 30 * s, 1.0f, 0.62f, 0.15f, 1);
	for (size_t i = 0; i < g_menuItems.size(); i++) {
		menu_rect((int)i, x, y, w, h);
		if ((int)i == g_menuSel) fill(x, y + 3 * s, w, h - 6 * s, 0.25f, 0.2f, 0.45f, 1);
		const char *l = g_menuItems[i].c_str();
		text(l, x + (w - text_width(l, 24 * s)) / 2, y + (h - 24 * s) / 2, 24 * s, 1, 1, 1, 1);
	}
}
static void draw_toast()
{
	if (g_toast.empty() || SDL_GetTicks() - g_toastAt > 1800) return;
	float s = ui_scale(), px = 22 * s, w = text_width(g_toast.c_str(), px) + 32 * s, h = 40 * s;
	float x = (g_W - w) / 2, y = g_H - h - 24 * s;
	fill(x, y, w, h, 0, 0, 0, 0.7f);
	text(g_toast.c_str(), x + 16 * s, y + (h - px) / 2, px, 1, 1, 1, 1);
}
static void draw_lines(const std::vector<std::string> &lines)
{
	float s = ui_scale(), px = 24 * s, y = (g_H - lines.size() * px * 1.5f) / 2;
	for (auto &l : lines) { text(l.c_str(), (g_W - text_width(l.c_str(), px)) / 2, y, px, 1, 1, 1, 1); y += px * 1.5f; }
}

// ------------------------------------------------------------------ input
static SDL_GameController *g_pads[PORTS];
static uint16_t g_prevCombo; static int g_testFrames;

static void pads_refresh()
{
	for (int i = 0; i < PORTS; i++) if (g_pads[i] && !SDL_GameControllerGetAttached(g_pads[i])) { SDL_GameControllerClose(g_pads[i]); g_pads[i] = NULL; }
	for (int j = 0; j < SDL_NumJoysticks(); j++) {
		if (!SDL_IsGameController(j)) continue;
		SDL_JoystickID id = SDL_JoystickGetDeviceInstanceID(j);
		bool have = false;
		for (int i = 0; i < PORTS; i++) if (g_pads[i] && SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(g_pads[i])) == id) have = true;
		if (have) continue;
		for (int i = 0; i < PORTS; i++) if (!g_pads[i]) { g_pads[i] = SDL_GameControllerOpen(j); if (g_pads[i]) SDL_GameControllerSetPlayerIndex(g_pads[i], i); break; }
	}
}
static uint16_t pad_bits(SDL_GameController *g)
{
	if (!g) return 0;
	uint16_t s = 0;
	auto B = [&](SDL_GameControllerButton b) { return SDL_GameControllerGetButton(g, b) != 0; };
	auto AX = [&](SDL_GameControllerAxis a) { return SDL_GameControllerGetAxis(g, a) / 32767.0f; };
	// Shoot = A (bottom), Pass = X (left, Y too), Turbo = B (right) or any shoulder / trigger.
	// In the core: retro A = Shoot, retro Y = Pass, retro B = Turbo.
	if (B(SDL_CONTROLLER_BUTTON_A)) s |= 1 << RETRO_DEVICE_ID_JOYPAD_A;
	if (B(SDL_CONTROLLER_BUTTON_X) || B(SDL_CONTROLLER_BUTTON_Y)) s |= 1 << RETRO_DEVICE_ID_JOYPAD_Y;
	if (B(SDL_CONTROLLER_BUTTON_B) || B(SDL_CONTROLLER_BUTTON_RIGHTSHOULDER) ||
	    AX(SDL_CONTROLLER_AXIS_TRIGGERRIGHT) > 0.5f || AX(SDL_CONTROLLER_AXIS_TRIGGERLEFT) > 0.5f) s |= 1 << RETRO_DEVICE_ID_JOYPAD_B;
	if (B(SDL_CONTROLLER_BUTTON_START)) s |= 1 << RETRO_DEVICE_ID_JOYPAD_START;
	if (B(SDL_CONTROLLER_BUTTON_BACK)) s |= 1 << RETRO_DEVICE_ID_JOYPAD_SELECT;
	float x = AX(SDL_CONTROLLER_AXIS_LEFTX), y = AX(SDL_CONTROLLER_AXIS_LEFTY);
	if (B(SDL_CONTROLLER_BUTTON_DPAD_UP) || y < -0.5f) s |= 1 << RETRO_DEVICE_ID_JOYPAD_UP;
	if (B(SDL_CONTROLLER_BUTTON_DPAD_DOWN) || y > 0.5f) s |= 1 << RETRO_DEVICE_ID_JOYPAD_DOWN;
	if (B(SDL_CONTROLLER_BUTTON_DPAD_LEFT) || x < -0.5f) s |= 1 << RETRO_DEVICE_ID_JOYPAD_LEFT;
	if (B(SDL_CONTROLLER_BUTTON_DPAD_RIGHT) || x > 0.5f) s |= 1 << RETRO_DEVICE_ID_JOYPAD_RIGHT;
	return s;
}
// keyboard: player 1 = arrows, Z/Space shoot, X pass, C/Shift turbo, 5 coin, 1 start
//           player 2 = W A S D, J shoot, K pass, L turbo, 6 coin, 2 start
static uint16_t key_bits(int player)
{
	const Uint8 *k = SDL_GetKeyboardState(NULL);
	uint16_t s = 0;
	struct M { SDL_Scancode a, b; int id; };
	static const M p1[] = {
		{ SDL_SCANCODE_UP, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_UP }, { SDL_SCANCODE_DOWN, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_DOWN },
		{ SDL_SCANCODE_LEFT, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_LEFT }, { SDL_SCANCODE_RIGHT, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_RIGHT },
		{ SDL_SCANCODE_Z, SDL_SCANCODE_SPACE, RETRO_DEVICE_ID_JOYPAD_A }, { SDL_SCANCODE_X, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_Y },
		{ SDL_SCANCODE_C, SDL_SCANCODE_LSHIFT, RETRO_DEVICE_ID_JOYPAD_B },
		{ SDL_SCANCODE_5, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_SELECT }, { SDL_SCANCODE_1, SDL_SCANCODE_RETURN, RETRO_DEVICE_ID_JOYPAD_START } };
	static const M p2[] = {
		{ SDL_SCANCODE_W, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_UP }, { SDL_SCANCODE_S, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_DOWN },
		{ SDL_SCANCODE_A, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_LEFT }, { SDL_SCANCODE_D, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_RIGHT },
		{ SDL_SCANCODE_J, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_A }, { SDL_SCANCODE_K, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_Y },
		{ SDL_SCANCODE_L, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_B },
		{ SDL_SCANCODE_6, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_SELECT }, { SDL_SCANCODE_2, SDL_SCANCODE_UNKNOWN, RETRO_DEVICE_ID_JOYPAD_START } };
	const M *m = player ? p2 : p1;
	for (int i = 0; i < 9; i++)
		if (k[m[i].a] || (m[i].b != SDL_SCANCODE_UNKNOWN && k[m[i].b])) s |= 1 << m[i].id;
	return s;
}

// ------------------------------------------------------------------ states, actions
static std::string g_romName = "nbajamrw";          // core driver / zip name (nbajamrwb = BLEEP version)
static std::string state_path() { return g_saveDir + "/" + g_romName + ".state"; }
static void save_state()
{
	if (!g_loaded) return;
	size_t n = retro_serialize_size(); std::vector<uint8_t> d(n);
	if (n && retro_serialize(d.data(), n)) {
		FILE *f = fopen(state_path().c_str(), "wb");
		if (f) { fwrite(d.data(), 1, n, f); fclose(f); toast("State saved"); return; }
	}
	toast("Could not save the state");
}
static void load_state()
{
	if (!g_loaded) return;
	FILE *f = fopen(state_path().c_str(), "rb");
	if (!f) { toast("No saved state yet"); return; }
	std::vector<uint8_t> d; uint8_t buf[65536]; size_t n;
	while ((n = fread(buf, 1, sizeof buf, f)) > 0) d.insert(d.end(), buf, buf + n);
	fclose(f);
	if (retro_unserialize(d.data(), d.size())) toast("State loaded"); else toast("Could not load the state");
}
static void set_crt(bool on) { g_crtOn = on; g_accValid = false; save_settings(); menu_build(); }
static void set_fullscreen(bool on)
{
	g_fullscreen = on;
	SDL_SetWindowFullscreen(g_win, on ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
	SDL_ShowCursor(SDL_ENABLE);
	save_settings(); menu_build();
}
static bool g_quit;
static void menu_activate(int i)
{
	switch (i) {
	case 0: g_menuOpen = false; break;
	case 1: save_state(); g_menuOpen = false; break;
	case 2: load_state(); g_menuOpen = false; break;
	case 3: set_crt(!g_crtOn); break;
	case 4: set_fullscreen(!g_fullscreen); break;
	case 5: g_testFrames = 6; g_menuOpen = false; break;
	case 6: if (g_loaded) retro_reset(); g_menuOpen = false; break;
	case 7: g_quit = true; break;
	}
}

// ------------------------------------------------------------------ game loading
// nbajamrw.zip = Rewind 1.1, nbajamrwb.zip = Rewind 1.1 with "Get that BLEEP outta here" (two core drivers)
static std::string rom_path_for(int v) { return g_base + (v == ROMSET_REWIND_BLEEP ? "nbajamrwb.zip" : "nbajamrw.zip"); }
static std::string rom_path() { return file_exists(rom_path_for(ROMSET_REWIND_BLEEP)) ? rom_path_for(ROMSET_REWIND_BLEEP) : rom_path_for(ROMSET_REWIND); }
static std::string g_loadError;
static std::string rom_problem(int v)
{
	if (v == ROMSET_UNPATCHED) return "This is the original romset: apply the NBA Jam Rewind 1.1 patches to it first.";
	return "This zip is not NBA Jam TE rev 2.1 with the NBA Jam Rewind 1.1 patches.";
}
static bool start_game()
{
	std::string p = rom_path();
	if (!file_exists(p)) return false;
	int v = romset_variant(p.c_str());
	if (v != ROMSET_REWIND && v != ROMSET_REWIND_BLEEP) { g_loadError = rom_problem(v); return false; }
	if (p != rom_path_for(v)) { remove(rom_path_for(v).c_str()); rename(p.c_str(), rom_path_for(v).c_str()); }   // name must match the driver
	g_romName = v == ROMSET_REWIND_BLEEP ? "nbajamrwb" : "nbajamrw";
	static bool inited = false;
	retro_set_environment(core_env);
	retro_set_video_refresh(core_video);
	retro_set_audio_sample(core_audio);
	retro_set_audio_sample_batch(core_audio_batch);
	retro_set_input_poll(core_poll);
	retro_set_input_state(core_input);
	if (!inited) { retro_init(); inited = true; }
	static std::string path; path = rom_path_for(v);
	struct retro_game_info gi = { path.c_str(), NULL, 0, NULL };
	if (!retro_load_game(&gi)) { g_loadError = rom_problem(ROMSET_UNKNOWN); return false; }
	for (unsigned i = 0; i < PORTS; i++) retro_set_controller_port_device(i, RETRO_DEVICE_JOYPAD);
	struct retro_system_av_info av; retro_get_system_av_info(&av);
	if (av.timing.fps > 0) g_fps = av.timing.fps;
	if (av.timing.sample_rate > 0) g_rate = av.timing.sample_rate;
	if (av.geometry.aspect_ratio > 0) g_aspect = av.geometry.aspect_ratio;
	g_loaded = true; g_loadError.clear();
	return true;
}
static void install_rom(const char *path)
{
	if (g_loaded) { toast("Restart the program to use another zip"); return; }
	std::string tmp = g_base + "import.zip.tmp";
	if (!copy_file(path, tmp)) { g_loadError = "Could not copy the file."; return; }
	int v = romset_variant(tmp.c_str());
	if (v != ROMSET_REWIND && v != ROMSET_REWIND_BLEEP) { remove(tmp.c_str()); g_loadError = rom_problem(v); return; }
	remove(rom_path_for(ROMSET_REWIND).c_str()); remove(rom_path_for(ROMSET_REWIND_BLEEP).c_str());
	rename(tmp.c_str(), rom_path_for(v).c_str());
	start_game();
}

// ------------------------------------------------------------------ main
int main(int argc, char **argv)
{
	// test / screenshot options (used to check the build): --shot file.bmp --frames N [--crt] [--menu] [--coin]
	const char *shotPath = NULL; long shotFrames = 0; bool optCrt = false, optMenu = false, optCoin = false;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--shot") && i + 1 < argc) shotPath = argv[++i];
		else if (!strcmp(argv[i], "--frames") && i + 1 < argc) shotFrames = atol(argv[++i]);
		else if (!strcmp(argv[i], "--crt")) optCrt = true;
		else if (!strcmp(argv[i], "--menu")) optMenu = true;
		else if (!strcmp(argv[i], "--coin")) optCoin = true;
	}

	if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_GAMECONTROLLER) != 0) {
		SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "NBA Jam TE Widescreen", SDL_GetError(), NULL);
		return 1;
	}
	char *bp = SDL_GetBasePath(); g_base = bp ? bp : "./"; SDL_free(bp);
	g_saveDir = g_base + "saves";
	MKDIR(g_saveDir.c_str()); MKDIR((g_saveDir + "/fbneo").c_str());
	load_settings();
	if (optCrt) g_crtOn = true;

	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	g_win = SDL_CreateWindow("NBA Jam TE Widescreen", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 1280, 750,
	                         SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE |
	                         (g_fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0));
	SDL_GLContext ctx = g_win ? SDL_GL_CreateContext(g_win) : NULL;
	if (!ctx || !gfx_init()) {
		SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "NBA Jam TE Widescreen", "OpenGL 3.3 is required.", g_win);
		return 1;
	}
	SDL_GL_SetSwapInterval(1);
	SDL_GameControllerEventState(SDL_ENABLE);
	pads_refresh();

	start_game();

	SDL_AudioSpec want = {}, have = {};
	want.freq = (int)lround(g_rate); want.format = AUDIO_S16SYS; want.channels = 2; want.samples = 512; want.callback = audio_cb;
	SDL_AudioDeviceID audio = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
	if (audio) SDL_PauseAudioDevice(audio, 0);

	if (optMenu) menu_open();
	show_bar();
	Uint64 freq = SDL_GetPerformanceFrequency(), last = SDL_GetPerformanceCounter();
	double acc = 0; long framesRun = 0;
	while (!g_quit) {
		SDL_Event e;
		while (SDL_PollEvent(&e)) {
			switch (e.type) {
			case SDL_QUIT: g_quit = true; break;
			case SDL_CONTROLLERDEVICEADDED: case SDL_CONTROLLERDEVICEREMOVED: pads_refresh(); break;
			case SDL_DROPFILE: install_rom(e.drop.file); SDL_free(e.drop.file); break;
			case SDL_MOUSEMOTION:
				g_mouseX = e.motion.x; g_mouseY = e.motion.y;
				if (e.motion.y < g_H / 4 || g_menuOpen) show_bar();
				if (g_menuOpen) { int h = menu_hit(g_mouseX, g_mouseY); if (h >= 0) g_menuSel = h; }
				break;
			case SDL_MOUSEBUTTONDOWN:
				if (e.button.button != SDL_BUTTON_LEFT) break;
				g_mouseX = e.button.x; g_mouseY = e.button.y;
				if (g_menuOpen) { int h = menu_hit(g_mouseX, g_mouseY); if (h >= 0) menu_activate(h); else if (bar_hit(g_mouseX, g_mouseY) < 0) g_menuOpen = false; break; }
				{
					bool wasVisible = g_barVisible;
					if (e.button.y < g_H / 4) show_bar();
					int b = wasVisible ? bar_hit(g_mouseX, g_mouseY) : -1;
					if (b == B_COIN) g_clickBits |= 1 << RETRO_DEVICE_ID_JOYPAD_SELECT;
					if (b == B_START) g_clickBits |= 1 << RETRO_DEVICE_ID_JOYPAD_START;
					if (b == B_MENU) menu_open();
					if (b == B_CRT) set_crt(!g_crtOn);
					g_mouseDownBtn = b;
				}
				break;
			case SDL_MOUSEBUTTONUP:
				if (e.button.button == SDL_BUTTON_LEFT) { g_clickBits = 0; g_mouseDownBtn = -1; }
				break;
			case SDL_KEYDOWN: {
				SDL_Keycode k = e.key.keysym.sym;
				if (k == SDLK_RETURN && (e.key.keysym.mod & KMOD_ALT)) { set_fullscreen(!g_fullscreen); break; }
				if (k == SDLK_F11) { set_fullscreen(!g_fullscreen); break; }
				if (k == SDLK_F2) { save_state(); break; }
				if (k == SDLK_F4) { load_state(); break; }
				if (k == SDLK_F3) { set_crt(!g_crtOn); break; }
				if (g_menuOpen) {
					if (k == SDLK_ESCAPE || k == SDLK_F1) g_menuOpen = false;
					else if (k == SDLK_UP) g_menuSel = (g_menuSel + (int)g_menuItems.size() - 1) % (int)g_menuItems.size();
					else if (k == SDLK_DOWN) g_menuSel = (g_menuSel + 1) % (int)g_menuItems.size();
					else if (k == SDLK_RETURN || k == SDLK_SPACE || k == SDLK_z) menu_activate(g_menuSel);
				} else if (k == SDLK_ESCAPE || k == SDLK_F1) menu_open();
				break;
			}
			case SDL_CONTROLLERBUTTONDOWN:
				if (g_menuOpen) {
					int b = e.cbutton.button;
					if (b == SDL_CONTROLLER_BUTTON_DPAD_UP) g_menuSel = (g_menuSel + (int)g_menuItems.size() - 1) % (int)g_menuItems.size();
					else if (b == SDL_CONTROLLER_BUTTON_DPAD_DOWN) g_menuSel = (g_menuSel + 1) % (int)g_menuItems.size();
					else if (b == SDL_CONTROLLER_BUTTON_A) menu_activate(g_menuSel);
					else if (b == SDL_CONTROLLER_BUTTON_B || b == SDL_CONTROLLER_BUTTON_GUIDE) g_menuOpen = false;
				} else if (e.cbutton.button == SDL_CONTROLLER_BUTTON_GUIDE) menu_open();
				break;
			case SDL_WINDOWEVENT:
				if (e.window.event == SDL_WINDOWEVENT_FOCUS_LOST && g_loaded) nbajamrw_save_nvram();
				break;
			}
		}
		SDL_GL_GetDrawableSize(g_win, &g_W, &g_H);

		// input
		uint16_t st[PORTS] = { 0, 0, 0, 0 };
		uint16_t combo = 0;
		for (int i = 0; i < PORTS; i++) st[i] = pad_bits(g_pads[i]);
		if (g_pads[0]) {
			SDL_GameController *g = g_pads[0];
			bool lb = SDL_GameControllerGetButton(g, SDL_CONTROLLER_BUTTON_LEFTSHOULDER);
			if (SDL_GameControllerGetButton(g, SDL_CONTROLLER_BUTTON_LEFTSTICK) && SDL_GameControllerGetButton(g, SDL_CONTROLLER_BUTTON_RIGHTSTICK)) combo |= 1;
			if (lb && SDL_GameControllerGetButton(g, SDL_CONTROLLER_BUTTON_START)) combo |= 2;
			if (lb && SDL_GameControllerGetButton(g, SDL_CONTROLLER_BUTTON_BACK)) combo |= 4;
			if (lb) st[0] &= ~((1 << RETRO_DEVICE_ID_JOYPAD_START) | (1 << RETRO_DEVICE_ID_JOYPAD_SELECT));
		}
		uint16_t pressed = combo & ~g_prevCombo; g_prevCombo = combo;
		if (pressed & 1) menu_open();
		if (pressed & 2) save_state();
		if (pressed & 4) load_state();
		if (!g_menuOpen) { st[0] |= key_bits(0) | g_clickBits; st[1] |= key_bits(1); }
		else for (int i = 0; i < PORTS; i++) st[i] = 0;
		if (optCoin && framesRun >= 60 && framesRun < 66) st[0] |= 1 << RETRO_DEVICE_ID_JOYPAD_B;   // test: skip the CMOS notice
		if (g_testFrames > 0) {
			st[0] = (1 << RETRO_DEVICE_ID_JOYPAD_START) | (1 << RETRO_DEVICE_ID_JOYPAD_L) | (1 << RETRO_DEVICE_ID_JOYPAD_R);
			g_testFrames--;
		}
		for (int i = 0; i < PORTS; i++) g_pad[i] = st[i];

		// timing: emulated frames at the arcade's rate, independent of the display's refresh
		Uint64 now = SDL_GetPerformanceCounter();
		double dt = (double)(now - last) / freq; last = now;
		int runs = 0;
		if (g_loaded && !g_menuOpen) {
			double spf = g_rate / g_fps;
			double fill = (double)(g_rw.load() - g_rr.load());
			double target = 4 * spf;
			double adj = (target - fill) / target * 0.005;
			if (adj > 0.005) adj = 0.005;
			if (adj < -0.005) adj = -0.005;
			g_ratio = 1.0 + adj;
			acc += dt;
			while (acc >= 1.0 / g_fps && runs < 3) { acc -= 1.0 / g_fps; runs++; }
			if (acc > 0.1) acc = 0;
			if (shotPath) runs = 1;                                     // test mode: one frame per loop
			for (int i = 0; i < runs; i++) { retro_run(); framesRun++; }
		} else acc = 0;
		if (g_newFrame) { g_newFrame = false; upload_frame(); }

		draw_game();
		glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
		if (!g_loaded) {
			std::vector<std::string> lines = { "NBA Jam TE Rewind - Widescreen", "",
				"Drag and drop your NBA Jam TE rev 2.1 romset (nbajamte2.zip)",
				"with the NBA Jam Rewind 1.1 patches applied (with or without the BLEEP",
				"extra) onto this window, or copy it next to the program as nbajamrw.zip."
 };
			if (!g_loadError.empty()) { lines.push_back(""); lines.push_back(g_loadError); }
			draw_lines(lines);
		} else {
			draw_bar();
			draw_menu();
			draw_toast();
		}
		glDisable(GL_BLEND);

		if (shotPath && (framesRun >= shotFrames || (!g_loaded && shotFrames == 0))) {
			std::vector<uint8_t> px(g_W * g_H * 4);
			glReadPixels(0, 0, g_W, g_H, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
			SDL_Surface *s = SDL_CreateRGBSurfaceWithFormat(0, g_W, g_H, 32, SDL_PIXELFORMAT_ABGR8888);
			for (int y = 0; y < g_H; y++) memcpy((uint8_t *)s->pixels + y * s->pitch, &px[(g_H - 1 - y) * g_W * 4], g_W * 4);
			SDL_SaveBMP(s, shotPath); SDL_FreeSurface(s);
			break;
		}
		SDL_GL_SwapWindow(g_win);
		if (runs == 0 && dt < 0.002) SDL_Delay(1);          // no vsync: don't spin
	}
	if (g_loaded) { nbajamrw_save_nvram(); retro_unload_game(); }
	retro_deinit();
	SDL_Quit();
	return 0;
}
