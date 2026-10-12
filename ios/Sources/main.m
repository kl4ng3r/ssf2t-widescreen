// SSF2T Widescreen for iOS 17+: a minimal libretro frontend around the statically linked
// FinalBurn Neo core (ssf2tws driver). Video via CALayer, audio via RemoteIO, input via the
// GameController framework (physical pads, or an on-screen GCVirtualController when none).
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdatomic.h>
#include "libretro.h"

extern void ssf2tws_save_nvram(void);

// ---------------------------------------------------------------- core glue (C)
static char g_dir[1024];                       // Documents: system/save dir and ROM location
static enum retro_pixel_format g_fmt = RETRO_PIXEL_FORMAT_0RGB1555;
static uint32_t *g_frame; static unsigned g_fw, g_fh; static int g_newFrame;
static uint16_t g_pad[2];                      // retro joypad bitmask per port
static float g_aspect = 16.0f / 9.0f;
static int g_loaded;                           // game loaded (safe to save EEPROM)

#define RING 16384                             // audio ring, stereo frames (power of two)
static int16_t g_ring[RING * 2];
static _Atomic uint32_t g_rw, g_rr;

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
// The core runs once per display refresh (smooth scrolling), which is slightly faster or slower
// than the arcade's 59.63 Hz, so its audio is resampled by g_ratio (output/input frames), which
// tick adjusts a little to keep the buffer level steady (dynamic rate control).
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
	if (port > 1 || (dev & RETRO_DEVICE_MASK) != RETRO_DEVICE_JOYPAD) return 0;
	if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)g_pad[port];
	return (g_pad[port] >> id) & 1;
}
static OSStatus audio_render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                             UInt32 bus, UInt32 n, AudioBufferList *io)
{
	int16_t *out = io->mBuffers[0].mData;
	uint32_t r = atomic_load(&g_rr), w = atomic_load(&g_rw);
	for (UInt32 i = 0; i < n; i++) {
		if (r != w) { out[i * 2] = g_ring[(r & (RING - 1)) * 2]; out[i * 2 + 1] = g_ring[(r & (RING - 1)) * 2 + 1]; r++; }
		else { out[i * 2] = 0; out[i * 2 + 1] = 0; }
	}
	atomic_store(&g_rr, r);
	return noErr;
}

// ---------------------------------------------------------------- view controller
@interface GameVC : UIViewController <UIDocumentPickerDelegate>
@end

@implementation GameVC {
	CALayer *_screen; CGColorSpaceRef _cs;
	CADisplayLink *_link; AudioUnit _au;
	BOOL _running, _paused, _menuOpen, _odd; double _rate, _fps;
	int _testFrames; uint16_t _prevCombo;
	GCVirtualController *_virtual; UIStackView *_bar; UIView *_help;
	uint16_t _touchBits;                         // coin/start held via on-screen buttons
}

- (NSString *)docs { return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject; }
- (NSString *)romPath { return [self.docs stringByAppendingPathComponent:@"ssf2t.zip"]; }

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
	[self.view addSubview:_bar];
	[NSLayoutConstraint activateConstraints:@[
		[_bar.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[_bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4] ]];

	NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
	[nc addObserver:self selector:@selector(controllersChanged) name:GCControllerDidConnectNotification object:nil];
	[nc addObserver:self selector:@selector(controllersChanged) name:GCControllerDidDisconnectNotification object:nil];
	[nc addObserver:self selector:@selector(willResign) name:UIApplicationWillResignActiveNotification object:nil];
	[nc addObserver:self selector:@selector(didBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
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
	if (tag < 0) [b addTarget:self action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];
	else {
		[b addTarget:self action:@selector(barDown:) forControlEvents:UIControlEventTouchDown];
		[b addTarget:self action:@selector(barUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
	}
	return b;
}
- (void)barDown:(UIButton *)b { _touchBits |= 1 << b.tag; }
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
	[_help removeFromSuperview]; _help = nil;
	// empty zip used as the launch target; the core finds the data in ssf2t.zip next to it
	NSString *stub = [self.docs stringByAppendingPathComponent:@"ssf2tws.zip"];
	if (![NSFileManager.defaultManager fileExistsAtPath:stub]) {
		static const uint8_t eocd[22] = { 0x50, 0x4b, 0x05, 0x06 };
		[[NSData dataWithBytes:eocd length:22] writeToFile:stub atomically:YES];
	}
	static BOOL inited = NO;
	retro_set_environment(core_env);
	retro_set_video_refresh(core_video);
	retro_set_audio_sample(core_audio);
	retro_set_audio_sample_batch(core_audio_batch);
	retro_set_input_poll(core_poll);
	retro_set_input_state(core_input);
	if (!inited) { retro_init(); inited = YES; }
	struct retro_game_info gi = { stub.fileSystemRepresentation, NULL, 0, NULL };
	if (!retro_load_game(&gi)) {
		[self alert:@"Could not start the game" message:@"Check that ssf2t.zip is the MAME/FBNeo romset for Super Street Fighter II Turbo (World 940223)."];
		return;
	}
	g_loaded = 1;
	retro_set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
	retro_set_controller_port_device(1, RETRO_DEVICE_JOYPAD);
	struct retro_system_av_info av; retro_get_system_av_info(&av);
	_rate = av.timing.sample_rate > 0 ? av.timing.sample_rate : 48000;
	_fps = av.timing.fps > 0 ? av.timing.fps : 59.63;
	if (av.geometry.aspect_ratio > 0) g_aspect = av.geometry.aspect_ratio;
	[self.view setNeedsLayout];
	[self startAudio];
	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
	_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);   // 120 Hz screens: see tick
	[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	_running = YES;
}

- (void)showHelp
{
	if (_help) return;
	_help = [[UIView alloc] initWithFrame:self.view.bounds];
	_help.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	UILabel *l = [[UILabel alloc] init];
	l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter; l.textColor = UIColor.whiteColor;
	l.text = @"Super Street Fighter II Turbo – Widescreen\n\nThis app needs your own ssf2t.zip (MAME/FBNeo romset, World 940223).\nTap Import below, or copy it with the Files app into\nOn My iPhone › SSF2T Widescreen, then reopen the app.";
	l.translatesAutoresizingMaskIntoConstraints = NO;
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	[b setTitle:@"Import ssf2t.zip" forState:UIControlStateNormal];
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
	[fm removeItemAtPath:self.romPath error:nil];
	NSError *err = nil;
	[fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:self.romPath] error:&err];
	if (scoped) [url stopAccessingSecurityScopedResource];
	if (err) { [self alert:@"Import failed" message:err.localizedDescription]; return; }
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
	for (NSUInteger i = 0; i < pads.count; i++) ((GCController *)pads[i]).playerIndex = i < 2 ? (GCControllerPlayerIndex)i : GCControllerPlayerIndexUnset;
	if (pads.count == 0 && !_virtual) {                 // touch controls: d-pad + 6 buttons
		GCVirtualControllerConfiguration *cfg = [[GCVirtualControllerConfiguration alloc] init];
		cfg.elements = [NSSet setWithArray:@[ GCInputDirectionPad, GCInputButtonA, GCInputButtonB, GCInputButtonX,
		                                       GCInputButtonY, GCInputRightShoulder, GCInputRightTrigger ]];
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
	// LP MP HP = X Y RB,  LK MK HK = A B RT (LT too); arcade layout of a 6-button pad
	if (g.buttonX.pressed) s |= 1 << RETRO_DEVICE_ID_JOYPAD_Y;
	if (g.buttonY.pressed) s |= 1 << RETRO_DEVICE_ID_JOYPAD_X;
	if (g.rightShoulder.pressed) s |= 1 << RETRO_DEVICE_ID_JOYPAD_L;
	if (g.buttonA.pressed) s |= 1 << RETRO_DEVICE_ID_JOYPAD_B;
	if (g.buttonB.pressed) s |= 1 << RETRO_DEVICE_ID_JOYPAD_A;
	if (g.rightTrigger.pressed || g.leftTrigger.pressed) s |= 1 << RETRO_DEVICE_ID_JOYPAD_R;
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
	uint16_t st[2] = { 0, 0 };
	uint16_t combo = 0;                                 // menu shortcuts on player 1's pad
	if (pads.count) {
		for (NSUInteger i = 0; i < pads.count && i < 2; i++) st[i] = pad_bits(pads[i].extendedGamepad);
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
	if (_testFrames > 0) {                              // hold Start + L + R: the core opens the test menu
		st[0] = (1 << RETRO_DEVICE_ID_JOYPAD_START) | (1 << RETRO_DEVICE_ID_JOYPAD_L) | (1 << RETRO_DEVICE_ID_JOYPAD_R);
		_testFrames--;
	}
	g_pad[0] = st[0]; g_pad[1] = st[1];
}

// ---------------------------------------------------------------- main loop
- (void)tick
{
	if (!_running || _paused) return;
	[self readInput];
	if (_paused) return;
	// one emulated frame per display refresh; audio is stretched to match (see core_audio_batch)
	double hz = 60.0;
	if (_link.targetTimestamp > _link.timestamp) hz = 1.0 / (_link.targetTimestamp - _link.timestamp);
	if (hz < 50 || hz > 130) hz = 60.0;
	int runs = 1;
	if (hz > 100) { _odd = !_odd; runs = _odd ? 1 : 0; hz /= 2; }   // 120 Hz screen: every other refresh
	double spf = _rate / _fps;                                       // output frames per emulated frame
	double fill = (double)(atomic_load(&g_rw) - atomic_load(&g_rr));
	double target = 4 * spf;
	double adj = (target - fill) / target * 0.005;                   // up to +-0.5 % to hold the level
	if (adj > 0.005) adj = 0.005; if (adj < -0.005) adj = -0.005;
	g_ratio = (_fps / hz) * (1.0 + adj);
	if (fill < spf && runs) runs = 2;                                // underrun (e.g. after a pause): catch up once
	for (int i = 0; i < runs; i++) retro_run();
	if (g_newFrame && g_frame) {
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

// ---------------------------------------------------------------- menu & states
- (NSString *)statePath { return [self.docs stringByAppendingPathComponent:@"ssf2tws.state"]; }
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
	UIAlertController *m = [UIAlertController alertControllerWithTitle:@"SSF2T Widescreen" message:nil preferredStyle:UIAlertControllerStyleAlert];
	__weak GameVC *ws = self;
	void (^done)(void) = ^{ GameVC *s = ws; if (s) { s->_menuOpen = NO; s->_paused = NO; } };
	[m addAction:[UIAlertAction actionWithTitle:@"Resume" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { done(); }]];
	[m addAction:[UIAlertAction actionWithTitle:@"Save State" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [ws saveState]; done(); }]];
	[m addAction:[UIAlertAction actionWithTitle:@"Load State" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [ws loadState]; done(); }]];
	[m addAction:[UIAlertAction actionWithTitle:@"Test Menu (difficulty etc.)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		GameVC *s = ws; if (s) s->_testFrames = 6; done(); }]];
	[m addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
		GameVC *s = ws; if (s && s->_running) retro_reset(); done(); }]];
	[m addAction:[UIAlertAction actionWithTitle:@"Import ssf2t.zip…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [ws importRom]; }]];
	[self presentViewController:m animated:YES completion:nil];
}

// ---------------------------------------------------------------- lifecycle
- (void)willResign
{
	_paused = YES;
	if (g_loaded) ssf2tws_save_nvram();             // iOS may close the app without warning
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
- (void)applicationWillTerminate:(UIApplication *)app { if (g_loaded) ssf2tws_save_nvram(); }
@end

int main(int argc, char *argv[])
{
	@autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
