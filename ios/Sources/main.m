// NBA Jam TE Rewind Widescreen for iOS 17+: a minimal libretro frontend around the statically
// linked FinalBurn Neo core (nbajamrw driver). Video via CALayer, audio via RemoteIO, input via the
// GameController framework (physical pads, or an on-screen GCVirtualController when none).
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdatomic.h>
#include "libretro.h"
#include "romcheck.h"

extern void nbajamrw_save_nvram(void);

// ---------------------------------------------------------------- core glue (C)
static char g_dir[1024];                       // Documents: system/save dir and ROM location
static enum retro_pixel_format g_fmt = RETRO_PIXEL_FORMAT_0RGB1555;
static uint32_t *g_frame; static unsigned g_fw, g_fh; static int g_newFrame;
#define PORTS 4
static uint16_t g_pad[PORTS];                  // retro joypad bitmask per port (4 players)
static float g_aspect = 16.0f / 9.0f;
static int g_loaded;                           // game loaded (safe to save EEPROM)

#define RING 65536                             // audio ring, stereo frames (power of two)
static int16_t g_ring[RING * 2];
static _Atomic uint32_t g_rw, g_rr;
static _Atomic uint32_t g_chunk = 512;          // frames iOS asked for in the last render call
static _Atomic uint32_t g_underruns;            // render calls that ran out of sound

static void core_log(enum retro_log_level l, const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
}
static bool core_env(unsigned cmd, void *data)
{
	switch (cmd) {
	case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: g_fmt = *(enum retro_pixel_format *)data; return true;
	case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
	case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: *(const char **)data = g_dir; return true;
	case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: ((struct retro_log_callback *)data)->log = core_log; return true;
	case RETRO_ENVIRONMENT_GET_CAN_DUPE: *(bool *)data = true; return true;
	case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: return true;
	case RETRO_ENVIRONMENT_SET_GEOMETRY: {
		const struct retro_game_geometry *g = data;
		if (g->aspect_ratio > 0) g_aspect = g->aspect_ratio;
		return true;
	}
	case RETRO_ENVIRONMENT_GET_VARIABLE: {     // only option we set: the test-menu button combo
		struct retro_variable *v = data;
		if (v && v->key && !strcmp(v->key, "fbneo-diagnostic-input")) { v->value = "Start + L + R"; return true; }
		return false;
	}
	default: return false;
	}
}
static void core_video(const void *data, unsigned w, unsigned h, size_t pitch)
{
	if (!data) return;
	if (w != g_fw || h != g_fh) { free(g_frame); g_frame = malloc(w * h * 4); g_fw = w; g_fh = h; }
	for (unsigned y = 0; y < h; y++) {
		const uint8_t *src = (const uint8_t *)data + y * pitch; uint32_t *dst = g_frame + y * w;
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
	g_newFrame = 1;
}
// Emulated frames are paced to the arcade's 54.71 Hz by tick; the audio is resampled by g_ratio
// (output/input frames), which tick nudges by up to 0.5 % to keep the buffer level steady.
static double g_ratio = 1.0, g_pos = 0.0;
static int16_t g_last[2];
static size_t core_audio_batch(const int16_t *d, size_t frames)
{
	uint32_t w = atomic_load(&g_rw), r = atomic_load(&g_rr);
	const double step = 1.0 / g_ratio;                   // input frames per output frame
	for (size_t i = 0; i < frames; ) {
		// output samples between previous input frame (g_last) and d[i], at fraction g_pos
		while (g_pos < 1.0) {
			if (w - r >= RING) { g_pos += step; continue; }   // full: drop
			double t = g_pos;
			for (int c = 0; c < 2; c++)
				g_ring[(w & (RING - 1)) * 2 + c] = (int16_t)(g_last[c] + (d[i * 2 + c] - g_last[c]) * t);
			w++; g_pos += step;
		}
		g_pos -= 1.0;
		g_last[0] = d[i * 2]; g_last[1] = d[i * 2 + 1];
		i++;
	}
	atomic_store(&g_rw, w);
	return frames;
}
static void core_audio(int16_t l, int16_t r) { int16_t s[2] = { l, r }; core_audio_batch(s, 1); }
static void core_poll(void) {}
static int16_t core_input(unsigned port, unsigned dev, unsigned idx, unsigned id)
{
	if (port >= PORTS || (dev & RETRO_DEVICE_MASK) != RETRO_DEVICE_JOYPAD) return 0;
	if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)g_pad[port];
	return (g_pad[port] >> id) & 1;
}
static OSStatus audio_render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                             UInt32 bus, UInt32 n, AudioBufferList *io)
{
	int16_t *out = io->mBuffers[0].mData;
	atomic_store(&g_chunk, n);
	uint32_t r = atomic_load(&g_rr), w = atomic_load(&g_rw);
	for (UInt32 i = 0; i < n; i++) {
		if (r != w) { out[i * 2] = g_ring[(r & (RING - 1)) * 2]; out[i * 2 + 1] = g_ring[(r & (RING - 1)) * 2 + 1]; r++; }
		else { out[i * 2] = 0; out[i * 2 + 1] = 0; }
	}
	if (r == w && n) atomic_fetch_add(&g_underruns, 1);
	atomic_store(&g_rr, r);
	return noErr;
}

// ---------------------------------------------------------------- view controller
@interface GameVC : UIViewController <UIDocumentPickerDelegate>
@end

@implementation GameVC {
	CALayer *_screen; CGColorSpaceRef _cs;
	CADisplayLink *_link; AudioUnit _au;
	BOOL _running, _paused, _menuOpen; double _rate, _fps, _acc; CFTimeInterval _lastTick; double _chunkMax; int _ticksSinceExtra;
	UIView *_topCatcher; NSTimer *_hideTimer; BOOL _barShown;
	int _testFrames; uint16_t _prevCombo;
	GCVirtualController *_virtual; UIStackView *_bar; UIView *_help;
	uint16_t _touchBits;                         // coin/start held via on-screen buttons
	// CRT filter (newpixie, Metal; see newpixie.metal)
	BOOL _crtOn; UIButton *_crtButton; CAMetalLayer *_crtLayer; uint32_t _crtFrame;
	id<MTLDevice> _dev; id<MTLCommandQueue> _queue; id<MTLSamplerState> _samp;
	id<MTLRenderPipelineState> _pAcc, _pBlurH, _pBlurV, _pCrt;
	id<MTLTexture> _tSrc, _tAcc[2], _tBlur1, _tBlur2; int _accIdx;
}

- (NSString *)docs { return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject; }
// nbajamrw.zip = Rewind 1.1, nbajamrwb.zip = Rewind 1.1 with "Get that BLEEP outta here" (two core drivers)
- (NSString *)romPathFor:(int)variant { return [self.docs stringByAppendingPathComponent:variant == ROMSET_REWIND_BLEEP ? @"nbajamrwb.zip" : @"nbajamrw.zip"]; }
- (NSString *)romPath
{
	NSString *b = [self romPathFor:ROMSET_REWIND_BLEEP];
	return [NSFileManager.defaultManager fileExistsAtPath:b] ? b : [self romPathFor:ROMSET_REWIND];
}
- (NSString *)romProblem:(int)v
{
	if (v == ROMSET_UNPATCHED) return @"This is the original NBA Jam TE rev 2.1 romset. Apply the NBA Jam Rewind 1.1 patches to it first, then import it again.";
	return @"This zip is not NBA Jam TE rev 2.1 (nbajamte2.zip) with the NBA Jam Rewind 1.1 patches applied.";
}
// gives the zip in Documents the name of the driver that matches its contents
- (BOOL)prepareRom
{
	NSString *p = self.romPath;
	int v = romset_variant(p.fileSystemRepresentation);
	if (v != ROMSET_REWIND && v != ROMSET_REWIND_BLEEP) { [self alert:@"Could not start the game" message:[self romProblem:v]]; return NO; }
	NSString *want = [self romPathFor:v];
	if (![want isEqualToString:p]) {
		[NSFileManager.defaultManager removeItemAtPath:want error:nil];
		[NSFileManager.defaultManager moveItemAtPath:p toPath:want error:nil];
	}
	return YES;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.blackColor;
	_cs = CGColorSpaceCreateDeviceRGB();
	_screen = [CALayer layer];
	_screen.magnificationFilter = kCAFilterLinear;
	_screen.backgroundColor = UIColor.blackColor.CGColor;
	[self.view.layer addSublayer:_screen];
	strlcpy(g_dir, self.docs.fileSystemRepresentation, sizeof g_dir);

	// on-screen Coin / Start / Menu (top centre), useful with touch and as a fallback
	_bar = [[UIStackView alloc] init];
	_bar.axis = UILayoutConstraintAxisHorizontal; _bar.spacing = 12; _bar.translatesAutoresizingMaskIntoConstraints = NO;
	[_bar addArrangedSubview:[self barButton:@"COIN" tag:RETRO_DEVICE_ID_JOYPAD_SELECT]];
	[_bar addArrangedSubview:[self barButton:@"START" tag:RETRO_DEVICE_ID_JOYPAD_START]];
	[_bar addArrangedSubview:[self barButton:@"MENU" tag:-1]];
	_crtButton = [self barButton:@"CRT" tag:-2];
	[_bar addArrangedSubview:_crtButton];
	_crtOn = [NSUserDefaults.standardUserDefaults boolForKey:@"crtFilter"];
	[self setupCRT];
	[self applyCRT];
	[self.view addSubview:_bar];
	[NSLayoutConstraint activateConstraints:@[
		[_bar.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[_bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4] ]];

	// the buttons hide after 5 s without a touch in the upper part of the screen; touching there shows them
	_topCatcher = [[UIView alloc] init];
	_topCatcher.backgroundColor = UIColor.clearColor;
	_topCatcher.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view insertSubview:_topCatcher belowSubview:_bar];
	[NSLayoutConstraint activateConstraints:@[
		[_topCatcher.leftAnchor constraintEqualToAnchor:self.view.leftAnchor],
		[_topCatcher.rightAnchor constraintEqualToAnchor:self.view.rightAnchor],
		[_topCatcher.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[_topCatcher.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.25] ]];
	UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(topTouched)];
	tap.cancelsTouchesInView = NO;
	[_topCatcher addGestureRecognizer:tap];
	UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(topTouched)];
	press.minimumPressDuration = 0; press.cancelsTouchesInView = NO;
	[_topCatcher addGestureRecognizer:press];
	[self showBar];

	NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
	[nc addObserver:self selector:@selector(controllersChanged) name:GCControllerDidConnectNotification object:nil];
	[nc addObserver:self selector:@selector(controllersChanged) name:GCControllerDidDisconnectNotification object:nil];
	[nc addObserver:self selector:@selector(willResign) name:UIApplicationWillResignActiveNotification object:nil];
	[nc addObserver:self selector:@selector(didBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
	[nc addObserver:self selector:@selector(audioChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
	[nc addObserver:self selector:@selector(audioChanged:) name:AVAudioSessionInterruptionNotification object:nil];
	[nc addObserver:self selector:@selector(audioReset) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
}

- (UIButton *)barButton:(NSString *)title tag:(NSInteger)tag
{
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	[b setTitle:title forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
	[b setTitleColor:[UIColor colorWithWhite:1 alpha:0.75] forState:UIControlStateNormal];
	b.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.45];
	b.layer.cornerRadius = 8;
	b.contentEdgeInsets = UIEdgeInsetsMake(4, 12, 4, 12);
	b.tag = tag;
	if (tag == -2) [b addTarget:self action:@selector(toggleCRT) forControlEvents:UIControlEventTouchUpInside];
	else if (tag < 0) [b addTarget:self action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];
	else {
		[b addTarget:self action:@selector(barDown:) forControlEvents:UIControlEventTouchDown];
		[b addTarget:self action:@selector(barUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
	}
	return b;
}
- (void)barDown:(UIButton *)b { _touchBits |= 1 << b.tag; [self showBar]; }
- (void)barUp:(UIButton *)b { _touchBits &= ~(1 << b.tag); }

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidLayoutSubviews
{
	[super viewDidLayoutSubviews];
	CGSize s = self.view.bounds.size;
	CGFloat w = s.width, h = w / g_aspect;
	if (h > s.height) { h = s.height; w = h * g_aspect; }
	[CATransaction begin]; [CATransaction setDisableActions:YES];
	_screen.frame = CGRectMake((s.width - w) / 2, (s.height - h) / 2, w, h);
	if (_crtLayer) {
		_crtLayer.frame = _screen.frame;
		CGFloat sc = self.view.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
		_crtLayer.drawableSize = CGSizeMake(w * sc, h * sc);
	}
	[CATransaction commit];
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	[self controllersChanged];
	if (!_running) [self tryStart];
}

// ---------------------------------------------------------------- startup
- (void)tryStart
{
	if (![NSFileManager.defaultManager fileExistsAtPath:self.romPath]) { [self showHelp]; return; }
	if (![self prepareRom]) { [self showHelp]; return; }
	[_help removeFromSuperview]; _help = nil;
	static BOOL inited = NO;
	retro_set_environment(core_env);
	retro_set_video_refresh(core_video);
	retro_set_audio_sample(core_audio);
	retro_set_audio_sample_batch(core_audio_batch);
	retro_set_input_poll(core_poll);
	retro_set_input_state(core_input);
	if (!inited) { retro_init(); inited = YES; }
	struct retro_game_info gi = { self.romPath.fileSystemRepresentation, NULL, 0, NULL };
	if (!retro_load_game(&gi)) {
		[self alert:@"Could not start the game" message:@"Check that the file is NBA Jam TE rev 2.1 (nbajamte2.zip) with the NBA Jam Rewind 1.1 patches applied."];
		return;
	}
	g_loaded = 1;
	for (unsigned i = 0; i < PORTS; i++) retro_set_controller_port_device(i, RETRO_DEVICE_JOYPAD);
	struct retro_system_av_info av; retro_get_system_av_info(&av);
	_rate = av.timing.sample_rate > 0 ? av.timing.sample_rate : 48000;
	_fps = av.timing.fps > 0 ? av.timing.fps : 54.71;
	if (av.geometry.aspect_ratio > 0) g_aspect = av.geometry.aspect_ratio;
	[self.view setNeedsLayout];
	[self startAudio];
	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
	_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
	[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	_running = YES;
	UIApplication.sharedApplication.idleTimerDisabled = YES;   // controller play doesn't count as touching the screen
}

- (void)showHelp
{
	if (_help) return;
	_help = [[UIView alloc] initWithFrame:self.view.bounds];
	_help.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	UILabel *l = [[UILabel alloc] init];
	l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter; l.textColor = UIColor.whiteColor;
	l.text = @"NBA Jam TE Rewind – Widescreen\n\nThis app needs your own NBA Jam TE rev 2.1 romset (nbajamte2.zip)\nwith the NBA Jam Rewind 1.1 patches applied (with or without the BLEEP extra).\nTap Import below and pick that zip (any file name).";
	l.translatesAutoresizingMaskIntoConstraints = NO;
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	[b setTitle:@"Import patched nbajamte2.zip" forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont boldSystemFontOfSize:20];
	[b addTarget:self action:@selector(importRom) forControlEvents:UIControlEventTouchUpInside];
	b.translatesAutoresizingMaskIntoConstraints = NO;
	[_help addSubview:l]; [_help addSubview:b];
	[NSLayoutConstraint activateConstraints:@[
		[l.centerXAnchor constraintEqualToAnchor:_help.centerXAnchor],
		[l.centerYAnchor constraintEqualToAnchor:_help.centerYAnchor constant:-30],
		[l.widthAnchor constraintLessThanOrEqualToAnchor:_help.widthAnchor constant:-40],
		[b.centerXAnchor constraintEqualToAnchor:_help.centerXAnchor],
		[b.topAnchor constraintEqualToAnchor:l.bottomAnchor constant:24] ]];
	[self.view addSubview:_help];
}

- (void)importRom
{
	UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
	p.delegate = self;
	[self presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	if (urls.count) [self installRom:urls.firstObject];
	_menuOpen = NO; _paused = NO;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c { _menuOpen = NO; _paused = NO; }
- (void)installRom:(NSURL *)url
{
	BOOL scoped = [url startAccessingSecurityScopedResource];
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString *tmp = [self.docs stringByAppendingPathComponent:@"import.zip.tmp"];
	[fm removeItemAtPath:tmp error:nil];
	NSError *err = nil;
	[fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp] error:&err];
	if (scoped) [url stopAccessingSecurityScopedResource];
	if (err) { [self alert:@"Import failed" message:err.localizedDescription]; return; }
	int v = romset_variant(tmp.fileSystemRepresentation);
	if (v != ROMSET_REWIND && v != ROMSET_REWIND_BLEEP) {
		[fm removeItemAtPath:tmp error:nil];
		[self alert:@"Import failed" message:[self romProblem:v]];
		return;
	}
	[fm removeItemAtPath:[self romPathFor:ROMSET_REWIND] error:nil];
	[fm removeItemAtPath:[self romPathFor:ROMSET_REWIND_BLEEP] error:nil];
	[fm moveItemAtPath:tmp toPath:[self romPathFor:v] error:nil];
	if (!_running) [self tryStart];
	else [self alert:@"ROM replaced" message:@"Close and reopen the app to use the new file."];
}

- (void)alert:(NSString *)t message:(NSString *)m
{
	UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

// ---------------------------------------------------------------- audio
- (void)startAudio
{
	AVAudioSession *s = AVAudioSession.sharedInstance;
	[s setCategory:AVAudioSessionCategoryPlayback error:nil];
	[s setPreferredSampleRate:_rate error:nil];
	[s setPreferredIOBufferDuration:0.010 error:nil];
	[s setActive:YES error:nil];
	AudioComponentDescription d = { kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0 };
	AudioComponent c = AudioComponentFindNext(NULL, &d);
	if (!c || AudioComponentInstanceNew(c, &_au) != noErr) return;
	AudioStreamBasicDescription f = { 0 };
	f.mSampleRate = _rate; f.mFormatID = kAudioFormatLinearPCM;
	f.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
	f.mFramesPerPacket = 1; f.mChannelsPerFrame = 2; f.mBitsPerChannel = 16; f.mBytesPerFrame = 4; f.mBytesPerPacket = 4;
	AudioUnitSetProperty(_au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
	AURenderCallbackStruct cb = { audio_render, NULL };
	AudioUnitSetProperty(_au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
	AudioUnitInitialize(_au);
	AudioOutputUnitStart(_au);
}

// route changes (headphones, Bluetooth) and interruptions (calls, Siri) can stop the output unit
- (void)audioChanged:(NSNotification *)n
{
	if ([n.name isEqualToString:AVAudioSessionInterruptionNotification] &&
	    [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		if (!self->_au || self->_paused) return;
		[AVAudioSession.sharedInstance setActive:YES error:nil];
		AudioOutputUnitStop(self->_au); AudioOutputUnitStart(self->_au);
	});
}
// the audio system restarted: the old unit is gone, build a new one
- (void)audioReset
{
	dispatch_async(dispatch_get_main_queue(), ^{
		if (self->_au) { AudioOutputUnitStop(self->_au); AudioComponentInstanceDispose(self->_au); self->_au = NULL; }
		if (self->_running) [self startAudio];
	});
}

// ---------------------------------------------------------------- controllers
- (NSArray<GCController *> *)physicalPads
{
	NSMutableArray *a = [NSMutableArray array];
	for (GCController *c in GCController.controllers)
		if (c.extendedGamepad && !(_virtual && (c == _virtual.controller || _virtual.controller == nil))) [a addObject:c];
	return a;
}
- (void)controllersChanged
{
	NSArray *pads = self.physicalPads;
	for (NSUInteger i = 0; i < pads.count; i++) ((GCController *)pads[i]).playerIndex = i < PORTS ? (GCControllerPlayerIndex)i : GCControllerPlayerIndexUnset;
	if (pads.count == 0 && !_virtual) {                 // touch controls: d-pad + Shoot / Pass / Turbo
		GCVirtualControllerConfiguration *cfg = [[GCVirtualControllerConfiguration alloc] init];
		cfg.elements = [NSSet setWithArray:@[ GCInputDirectionPad, GCInputButtonA, GCInputButtonB, GCInputButtonX ]];
		_virtual = [[GCVirtualController alloc] initWithConfiguration:cfg];
		[_virtual connectWithReplyHandler:nil];
	} else if (pads.count > 0 && _virtual) {
		[_virtual disconnect]; _virtual = nil;
	}
}
static uint16_t pad_bits(GCExtendedGamepad *g)
{
	uint16_t s = 0;
	if (!g) return 0;
	// Shoot = A (bottom), Pass = X (left, Y too), Turbo = B (right) or any shoulder / trigger.
	// In the core: retro A = Shoot, retro Y = Pass, retro B = Turbo.
	if (g.buttonA.pressed) s |= 1 << RETRO_DEVICE_ID_JOYPAD_A;
	if (g.buttonX.pressed || g.buttonY.pressed) s |= 1 << RETRO_DEVICE_ID_JOYPAD_Y;
	if (g.buttonB.pressed || g.rightShoulder.pressed || g.rightTrigger.pressed || g.leftTrigger.pressed)
		s |= 1 << RETRO_DEVICE_ID_JOYPAD_B;
	if (g.buttonMenu.pressed) s |= 1 << RETRO_DEVICE_ID_JOYPAD_START;
	if (g.buttonOptions && g.buttonOptions.pressed) s |= 1 << RETRO_DEVICE_ID_JOYPAD_SELECT;
	float x = g.leftThumbstick.xAxis.value, y = g.leftThumbstick.yAxis.value;
	if (g.dpad.up.pressed || y > 0.5f) s |= 1 << RETRO_DEVICE_ID_JOYPAD_UP;
	if (g.dpad.down.pressed || y < -0.5f) s |= 1 << RETRO_DEVICE_ID_JOYPAD_DOWN;
	if (g.dpad.left.pressed || x < -0.5f) s |= 1 << RETRO_DEVICE_ID_JOYPAD_LEFT;
	if (g.dpad.right.pressed || x > 0.5f) s |= 1 << RETRO_DEVICE_ID_JOYPAD_RIGHT;
	return s;
}
- (void)readInput
{
	NSArray<GCController *> *pads = self.physicalPads;
	uint16_t st[PORTS] = { 0, 0, 0, 0 };
	uint16_t combo = 0;                                 // menu shortcuts on player 1's pad
	if (pads.count) {
		for (NSUInteger i = 0; i < pads.count && i < PORTS; i++) st[i] = pad_bits(pads[i].extendedGamepad);
		GCExtendedGamepad *g = pads[0].extendedGamepad;
		BOOL lb = g.leftShoulder.pressed;
		if (g.leftThumbstickButton.pressed && g.rightThumbstickButton.pressed) combo |= 1;   // L3+R3: menu
		if (lb && g.buttonMenu.pressed) combo |= 2;                                          // LB+Start: save
		if (lb && g.buttonOptions.pressed) combo |= 4;                                       // LB+Coin: load
		if (lb) st[0] &= ~((1 << RETRO_DEVICE_ID_JOYPAD_START) | (1 << RETRO_DEVICE_ID_JOYPAD_SELECT));
	} else if (_virtual) {
		st[0] = pad_bits(_virtual.controller.extendedGamepad);
	}
	st[0] |= _touchBits;
	uint16_t pressed = combo & ~_prevCombo; _prevCombo = combo;
	if (pressed & 1) [self showMenu];
	if (pressed & 2) [self saveState];
	if (pressed & 4) [self loadState];
	if (_testFrames > 0) {                              // hold Start + L + R: the core presses the test button
		st[0] = (1 << RETRO_DEVICE_ID_JOYPAD_START) | (1 << RETRO_DEVICE_ID_JOYPAD_L) | (1 << RETRO_DEVICE_ID_JOYPAD_R);
		_testFrames--;
	}
	for (int i = 0; i < PORTS; i++) g_pad[i] = st[i];
}

// ---------------------------------------------------------------- auto-hiding buttons
- (void)topTouched { [self showBar]; }
- (void)showBar
{
	[_hideTimer invalidate];
	_hideTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(hideBar) userInfo:nil repeats:NO];
	if (_barShown) return;
	_barShown = YES; _bar.userInteractionEnabled = YES;
	[UIView animateWithDuration:0.2 animations:^{ self->_bar.alpha = 1.0; }];
}
- (void)hideBar
{
	if (_menuOpen || _help) { [self showBar]; return; }
	_barShown = NO; _bar.userInteractionEnabled = NO;
	[UIView animateWithDuration:0.4 animations:^{ self->_bar.alpha = 0.0; }];
}
// ---------------------------------------------------------------- main loop
- (void)tick
{
	if (!_running || _paused) return;
	[self readInput];
	if (_paused) return;
	// The arcade runs at 54.71 Hz. Emulated frames are paced only by the real time between
	// display-link callbacks (a late or skipped callback still counts). The audio buffer is kept at
	// a level that covers the chunk size iOS currently pulls (it grows them when the screen dims or
	// for Bluetooth), with the resampler nudging up to +-1 %; at most one extra frame every half
	// second tops it up when it is about to run dry, so the game speed never follows the audio.
	CFTimeInterval now = _link.timestamp;
	double dt = _lastTick > 0 ? now - _lastTick : 1.0 / 60.0;
	_lastTick = now;
	if (dt < 0) dt = 0;
	if (dt > 0.1) dt = 0.1;                                          // after a pause / stall
	double spf = _rate / _fps;                                       // output frames per emulated frame
	double fill = (double)(atomic_load(&g_rw) - atomic_load(&g_rr));
	double chunk = atomic_load(&g_chunk);
	_chunkMax = chunk > _chunkMax * 0.999 ? chunk : _chunkMax * 0.999;
	double target = 6 * spf;                                         // ~110 ms of sound buffered
	if (target < 2.5 * _chunkMax + spf) target = 2.5 * _chunkMax + spf;
	double adj = (target - fill) / target * 0.01;
	if (adj > 0.01) adj = 0.01;
	if (adj < -0.01) adj = -0.01;
	g_ratio = 1.0 + adj;
	_acc += dt;
	int runs = 0;
	while (_acc >= 1.0 / _fps && runs < 6) { _acc -= 1.0 / _fps; runs++; }
	if (_acc > 0.2) _acc = 0;
	_ticksSinceExtra++;
	if (fill < _chunkMax && _ticksSinceExtra > 30) { runs++; _ticksSinceExtra = 0; }
	if (fill > RING - 4 * spf) runs = 0;                             // buffer full (audio not playing)
	for (int i = 0; i < runs; i++) retro_run();
	if (g_newFrame && g_frame && _crtOn && _pCrt) {
		g_newFrame = 0;
		[self renderCRT];
	} else if (g_newFrame && g_frame) {
		g_newFrame = 0;
		NSData *d = [NSData dataWithBytes:g_frame length:g_fw * g_fh * 4];
		CGDataProviderRef p = CGDataProviderCreateWithCFData((__bridge CFDataRef)d);
		CGImageRef img = CGImageCreate(g_fw, g_fh, 8, 32, g_fw * 4, _cs,
		                               kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, p, NULL, false, kCGRenderingIntentDefault);
		[CATransaction begin]; [CATransaction setDisableActions:YES];
		_screen.contents = (__bridge id)img;
		[CATransaction commit];
		CGImageRelease(img); CGDataProviderRelease(p);
	}
}

// ---------------------------------------------------------------- CRT filter
- (void)setupCRT
{
	_dev = MTLCreateSystemDefaultDevice();
	if (!_dev) return;
	_queue = [_dev newCommandQueue];
	id<MTLLibrary> lib = [_dev newDefaultLibrary];
	if (!lib) { NSLog(@"CRT: no Metal library"); return; }
	id<MTLFunction> vs = [lib newFunctionWithName:@"np_vertex"];
	_pAcc   = [self pipeline:lib vs:vs fs:@"np_accumulate"];
	_pBlurH = [self pipeline:lib vs:vs fs:@"np_blur_h"];
	_pBlurV = [self pipeline:lib vs:vs fs:@"np_blur_v"];
	_pCrt   = [self pipeline:lib vs:vs fs:@"np_crt"];
	MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
	sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
	sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToZero;    // RetroArch default: clamp to border (black)
	_samp = [_dev newSamplerStateWithDescriptor:sd];
	_crtLayer = [CAMetalLayer layer];
	_crtLayer.device = _dev;
	_crtLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	_crtLayer.framebufferOnly = YES;
	_crtLayer.backgroundColor = UIColor.blackColor.CGColor;
	_crtLayer.hidden = YES;
	[self.view.layer insertSublayer:_crtLayer above:_screen];
}
- (id<MTLRenderPipelineState>)pipeline:(id<MTLLibrary>)lib vs:(id<MTLFunction>)vs fs:(NSString *)name
{
	MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = vs; d.fragmentFunction = [lib newFunctionWithName:name];
	d.colorAttachments[0].pixelFormat = [name isEqualToString:@"np_crt"] ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA16Float;
	NSError *e = nil; id<MTLRenderPipelineState> p = [_dev newRenderPipelineStateWithDescriptor:d error:&e];
	if (!p) NSLog(@"CRT pipeline %@: %@", name, e);
	return p;
}
- (id<MTLTexture>)tex:(MTLPixelFormat)f w:(NSUInteger)w h:(NSUInteger)h rt:(BOOL)rt
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
	d.usage = MTLTextureUsageShaderRead | (rt ? MTLTextureUsageRenderTarget : 0);
	d.storageMode = rt ? MTLStorageModePrivate : MTLStorageModeShared;
	return [_dev newTextureWithDescriptor:d];
}
- (void)toggleCRT
{
	_crtOn = !_crtOn;
	[NSUserDefaults.standardUserDefaults setBool:_crtOn forKey:@"crtFilter"];
	[self applyCRT];
}
- (void)applyCRT
{
	BOOL on = _crtOn && _pCrt;
	_crtLayer.hidden = !on;
	_screen.hidden = on;
	[_crtButton setTitle:on ? @"CRT ON" : @"CRT" forState:UIControlStateNormal];
	_crtButton.backgroundColor = on ? [UIColor colorWithRed:0.1 green:0.45 blue:0.2 alpha:0.6] : [UIColor colorWithWhite:0.15 alpha:0.45];
	if (on) { _tAcc[0] = _tAcc[1] = nil; }                          // restart the phosphor buffer
	[self.view setNeedsLayout];
}
typedef struct { float outW, outH, frameCount, curvature, wiggle, scanroll, vignette, ghosting, accModulate, blurX, blurY, pad; } NPParams;
- (void)pass:(id<MTLCommandBuffer>)cb pipe:(id<MTLRenderPipelineState>)pipe to:(id<MTLTexture>)dst
          tex0:(id<MTLTexture>)t0 tex1:(id<MTLTexture>)t1 params:(NPParams)prm
{
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = dst;
	rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
	[e setRenderPipelineState:pipe];
	[e setFragmentTexture:t0 atIndex:0];
	if (t1) [e setFragmentTexture:t1 atIndex:1];
	[e setFragmentSamplerState:_samp atIndex:0];
	prm.outW = dst.width; prm.outH = dst.height;
	[e setFragmentBytes:&prm length:sizeof prm atIndex:0];
	[e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[e endEncoding];
}
- (void)renderCRT
{
	if (!_tSrc || _tSrc.width != g_fw || _tSrc.height != g_fh) {
		_tSrc = [self tex:MTLPixelFormatBGRA8Unorm w:g_fw h:g_fh rt:NO];
		_tAcc[0] = _tAcc[1] = nil; _tBlur1 = _tBlur2 = nil;
	}
	if (!_tAcc[0]) {
		_tAcc[0] = [self tex:MTLPixelFormatRGBA16Float w:g_fw h:g_fh rt:YES];
		_tAcc[1] = [self tex:MTLPixelFormatRGBA16Float w:g_fw h:g_fh rt:YES];
		_tBlur1 = [self tex:MTLPixelFormatRGBA16Float w:g_fw h:g_fh rt:YES];
		_tBlur2 = [self tex:MTLPixelFormatRGBA16Float w:g_fw h:g_fh rt:YES];
		// start the phosphor buffer from black
		id<MTLCommandBuffer> cb = [_queue commandBuffer];
		for (int i = 0; i < 2; i++) {
			MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
			rp.colorAttachments[0].texture = _tAcc[i]; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
			rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
			[[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
		}
		[cb commit];
	}
	[_tSrc replaceRegion:MTLRegionMake2D(0, 0, g_fw, g_fh) mipmapLevel:0 withBytes:g_frame bytesPerRow:g_fw * 4];
	id<CAMetalDrawable> drawable = [_crtLayer nextDrawable];
	if (!drawable) return;
	NPParams prm = { 0, 0, (float)_crtFrame++, 0.5f /* curvature */, 0.0f, 1.0f, 1.0f, 1.0f, 0.65f, 1.0f, 1.0f, 0 };
	id<MTLCommandBuffer> cb = [_queue commandBuffer];
	id<MTLTexture> prev = _tAcc[_accIdx], acc = _tAcc[_accIdx ^ 1];
	_accIdx ^= 1;
	[self pass:cb pipe:_pAcc   to:acc     tex0:prev    tex1:_tSrc params:prm];
	[self pass:cb pipe:_pBlurH to:_tBlur1 tex0:acc     tex1:nil   params:prm];
	[self pass:cb pipe:_pBlurV to:_tBlur2 tex0:_tBlur1 tex1:nil   params:prm];
	[self pass:cb pipe:_pCrt   to:drawable.texture tex0:acc tex1:_tBlur2 params:prm];
	[cb presentDrawable:drawable];
	[cb commit];
}

// ---------------------------------------------------------------- menu & states
- (NSString *)statePath { return [self.romPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"state"]; }
- (void)saveState
{
	if (!_running) return;
	size_t n = retro_serialize_size(); NSMutableData *d = [NSMutableData dataWithLength:n];
	if (n && retro_serialize(d.mutableBytes, n)) [d writeToFile:self.statePath atomically:YES];
}
- (void)loadState
{
	if (!_running) return;
	NSData *d = [NSData dataWithContentsOfFile:self.statePath];
	if (d.length) retro_unserialize(d.bytes, d.length);
}
- (void)showMenu
{
	if (_menuOpen) return;
	_menuOpen = YES; _paused = YES;
	double fill = (double)(atomic_load(&g_rw) - atomic_load(&g_rr));
	AVAudioSession *as = AVAudioSession.sharedInstance;
	NSString *info = [NSString stringWithFormat:@"Audio: %.0f Hz, chunk %u, IO %.0f ms, buffer %.0f ms, gaps %u",
	                  as.sampleRate, atomic_load(&g_chunk), as.IOBufferDuration * 1000, fill / (_rate > 0 ? _rate : 48000) * 1000, atomic_load(&g_underruns)];
	UIAlertController *m = [UIAlertController alertControllerWithTitle:@"NBA Jam TE Widescreen" message:info preferredStyle:UIAlertControllerStyleAlert];
	__weak GameVC *ws = self;
	void (^done)(void) = ^{ GameVC *s = ws; if (s) { s->_menuOpen = NO; s->_paused = NO; } };
	[m addAction:[UIAlertAction actionWithTitle:@"Resume" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { done(); }]];
	[m addAction:[UIAlertAction actionWithTitle:@"Save State" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [ws saveState]; done(); }]];
	[m addAction:[UIAlertAction actionWithTitle:@"Load State" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [ws loadState]; done(); }]];
	[m addAction:[UIAlertAction actionWithTitle:_crtOn ? @"CRT Filter: On" : @"CRT Filter: Off" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [ws toggleCRT]; done(); }]];
	[m addAction:[UIAlertAction actionWithTitle:@"Test Menu (difficulty, free play…)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		GameVC *s = ws; if (s) s->_testFrames = 6; done(); }]];
	[m addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
		GameVC *s = ws; if (s && s->_running) retro_reset(); done(); }]];
	[m addAction:[UIAlertAction actionWithTitle:@"Import ROM zip…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [ws importRom]; }]];
	[self presentViewController:m animated:YES completion:nil];
}

// ---------------------------------------------------------------- lifecycle
- (void)willResign
{
	_paused = YES;
	if (g_loaded) nbajamrw_save_nvram();             // iOS may close the app without warning
	if (_au) AudioOutputUnitStop(_au);
}
- (void)didBecomeActive
{
	if (_au) AudioOutputUnitStart(_au);
	if (!_menuOpen) _paused = NO;
}
- (void)openURL:(NSURL *)url { [self installRom:url]; }
@end

// ---------------------------------------------------------------- app delegate
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts
{
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	self.window.rootViewController = [[GameVC alloc] init];
	[self.window makeKeyAndVisible];
	return YES;
}
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)opts
{
	[(GameVC *)self.window.rootViewController openURL:url];
	return YES;
}
- (void)applicationWillTerminate:(UIApplication *)app { if (g_loaded) nbajamrw_save_nvram(); }
@end

int main(int argc, char *argv[])
{
	@autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
