/* etaf-video-mpv-macos.m --- Native macOS GPU video layer for etaf-video-mpv

   Embeds a hardware-accelerated CAOpenGLLayer backed by libmpv's OpenGL render
   API and Apple VideoToolbox zero-copy decoding directly inside the target
   Emacs NSWindow.  Requires no Emacs source patches or recompilation, passes
   all mouse and keyboard input straight through to Emacs, snaps geometry with
   CoreAnimation implicit actions disabled, and provides an offscreen FBO frame
   grab so in-buffer ETAF modals/overlays can composite cleanly above the
   current video frame.

   Copyright (C) 2026  ETAF contributors

   This file is free software: you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by the
   Free Software Foundation, either version 3 of the License, or (at your
   option) any later version.  */

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>

#include <dlfcn.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "etaf-video-mpv-internal.h"

static void *
etaf_gl_get_proc_address (void *ctx, const char *name)
{
	(void) ctx;
	static void *gl_lib = NULL;
	if (!gl_lib)
		gl_lib = dlopen("/System/Library/Frameworks/OpenGL.framework/Versions/Current/OpenGL",
		                RTLD_LAZY | RTLD_LOCAL);
	void *p = gl_lib ? dlsym(gl_lib, name) : NULL;
	return p ? p : dlsym(RTLD_DEFAULT, name);
}

struct etaf_mpv_gpu {
	const etaf_mpv_api *api;
	mpv_handle *mpv;
	mpv_render_context *mpv_gl;
	CGLPixelFormatObj cgl_pf;
	CGLContextObj cgl_ctx;
	CFTypeRef host_view_ref;   /* retained EtafMpvGLHostView */
	CFTypeRef gl_layer_ref;    /* retained EtafMpvGLLayer */
	CFTypeRef attached_win;    /* weak/unretained pointer comparison only */
	atomic_int refcount;
	atomic_int destroyed;
	atomic_int visible;
	atomic_int pending_update;
	atomic_int force_redraw;
	atomic_uint_fast64_t frames;
	double last_x, last_y, last_w, last_h, last_scale;
	bool has_rect;
};

static void
etaf_mpv_gpu_retain (etaf_mpv_gpu *gpu)
{
	atomic_fetch_add_explicit(&gpu->refcount, 1, memory_order_relaxed);
}

static void
etaf_mpv_gpu_release (etaf_mpv_gpu *gpu)
{
	if (atomic_fetch_sub_explicit(&gpu->refcount, 1, memory_order_acq_rel) == 1)
		free(gpu);
}

/* Transparent input pass-through NSView backed by EtafMpvGLLayer.  */
@interface EtafMpvGLHostView : NSView
@property (nonatomic, assign) etaf_mpv_gpu *gpu;
@end

/* CoreAnimation OpenGL layer driving libmpv GPU rendering.  */
@interface EtafMpvGLLayer : CAOpenGLLayer
@property (nonatomic, assign) etaf_mpv_gpu *gpu;
@end

@implementation EtafMpvGLHostView
- (CALayer *)makeBackingLayer
{
	EtafMpvGLLayer *layer = [EtafMpvGLLayer layer];
	layer.gpu = _gpu;
	layer.asynchronous = NO;
	layer.opaque = YES;
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGFloat bg_rgba[4] = { 5.0 / 255.0, 6.0 / 255.0, 7.0 / 255.0, 1.0 };
	CGColorRef bg = CGColorCreate(cs, bg_rgba);
	layer.backgroundColor = bg;
	CGColorRelease(bg);
	CGColorSpaceRelease(cs);
	return layer;
}

- (NSView *)hitTest:(NSPoint)point
{
	(void) point;
	return nil;
}

- (BOOL)acceptsFirstResponder
{
	return NO;
}

- (BOOL)mouseDownCanMoveWindow
{
	return NO;
}
@end

@implementation EtafMpvGLLayer

- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask
{
	(void) mask;
	if (_gpu && _gpu->cgl_pf)
		return CGLRetainPixelFormat(_gpu->cgl_pf);
	return [super copyCGLPixelFormatForDisplayMask:mask];
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pf
{
	if (_gpu && _gpu->cgl_ctx)
		return CGLRetainContext(_gpu->cgl_ctx);
	return [super copyCGLContextForPixelFormat:pf];
}

- (BOOL)canDrawInCGLContext:(CGLContextObj)ctx
                pixelFormat:(CGLPixelFormatObj)pf
               forLayerTime:(CFTimeInterval)t
                displayTime:(const CVTimeStamp *)ts
{
	(void) ctx; (void) pf; (void) t; (void) ts;
	etaf_mpv_gpu *g = _gpu;
	return g && !atomic_load_explicit(&g->destroyed, memory_order_acquire)
		&& g->mpv_gl != NULL;
}

- (void)drawInCGLContext:(CGLContextObj)ctx
             pixelFormat:(CGLPixelFormatObj)pf
            forLayerTime:(CFTimeInterval)t
             displayTime:(const CVTimeStamp *)ts
{
	etaf_mpv_gpu *g = _gpu;
	if (!g || atomic_load_explicit(&g->destroyed, memory_order_acquire) || !g->mpv_gl) {
		[super drawInCGLContext:ctx pixelFormat:pf forLayerTime:t displayTime:ts];
		return;
	}
	CGLLockContext(ctx);
	CGLSetCurrentContext(ctx);

	/* Ensure libmpv sees the current draw FBO and Retina pixel dimensions.  */
	g->api->render_context_update(g->mpv_gl);

	GLint fbo = 0;
	glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &fbo);
	CGSize sz = self.bounds.size;
	CGFloat s = self.contentsScale > 0.0 ? self.contentsScale : 1.0;
	int pw = (int) llround(sz.width * s);
	int ph = (int) llround(sz.height * s);
	if (pw > 0 && ph > 0) {
		etaf_mpv_opengl_fbo mfbo = {
			.fbo = fbo,
			.w = pw,
			.h = ph,
			.internal_format = 0
		};
		int flip = 1;
		int block = 0;
		etaf_mpv_render_param rparams[] = {
			{ ETAF_MPV_RP_OPENGL_FBO, &mfbo },
			{ ETAF_MPV_RP_FLIP_Y, &flip },
			{ ETAF_MPV_RP_BLOCK_FOR_TARGET_TIME, &block },
			{ ETAF_MPV_RP_INVALID, NULL }
		};
		if (g->api->render_context_render(g->mpv_gl, rparams) >= 0) {
			g->api->render_context_report_swap(g->mpv_gl);
			atomic_fetch_add_explicit(&g->frames, 1, memory_order_relaxed);
		}
	}
	CGLUnlockContext(ctx);
	[super drawInCGLContext:ctx pixelFormat:pf forLayerTime:t displayTime:ts];
}

@end

static void
etaf_mpv_gpu_on_update (void *cb_ctx)
{
	etaf_mpv_gpu *gpu = (etaf_mpv_gpu *) cb_ctx;
	if (!gpu || atomic_load_explicit(&gpu->destroyed, memory_order_acquire))
		return;
	if (atomic_exchange_explicit(&gpu->pending_update, 1, memory_order_acq_rel) != 0)
		return;

	etaf_mpv_gpu_retain(gpu);
	dispatch_async(dispatch_get_main_queue(), ^{
		atomic_store_explicit(&gpu->pending_update, 0, memory_order_release);
		if (!atomic_load_explicit(&gpu->destroyed, memory_order_acquire) && gpu->mpv_gl) {
			bool vis = atomic_load_explicit(&gpu->visible, memory_order_acquire) != 0;
			int force = atomic_exchange_explicit(&gpu->force_redraw, 0, memory_order_acq_rel);
			if (vis) {
				uint64_t flags = gpu->api->render_context_update(gpu->mpv_gl);
				if ((flags & ETAF_MPV_RENDER_UPDATE_FRAME) || force) {
					EtafMpvGLLayer *layer = (__bridge EtafMpvGLLayer *) gpu->gl_layer_ref;
					if (layer) {
						[layer setNeedsDisplay];
						[CATransaction flush];
					}
				}
			} else {
				/* Hidden: drain libmpv's frame notification with zero GPU draw
				   so audio clocks and decoder queues stay healthy at ~1% CPU.  */
				uint64_t flags = gpu->api->render_context_update(gpu->mpv_gl);
				if ((flags & ETAF_MPV_RENDER_UPDATE_FRAME) && gpu->cgl_ctx) {
					CGLLockContext(gpu->cgl_ctx);
					CGLSetCurrentContext(gpu->cgl_ctx);
					int skip = 1;
					int block = 0;
					etaf_mpv_render_param rparams[] = {
						{ ETAF_MPV_RP_SKIP_RENDERING, &skip },
						{ ETAF_MPV_RP_BLOCK_FOR_TARGET_TIME, &block },
						{ ETAF_MPV_RP_INVALID, NULL }
					};
					if (gpu->api->render_context_render(gpu->mpv_gl, rparams) >= 0) {
						gpu->api->render_context_report_swap(gpu->mpv_gl);
						/* Advance the frame counter even while occluded/hidden
						   so apps gating opening posters/spinners on `:presented'
						   unblock cleanly once libmpv decodes frame 1.  */
						atomic_fetch_add_explicit(&gpu->frames, 1, memory_order_relaxed);
					}
					CGLUnlockContext(gpu->cgl_ctx);
				}
			}
		}
		etaf_mpv_gpu_release(gpu);
	});
}

static NSWindow *
etaf_mpv_gpu_find_window (const char *title_hint,
                          double outer_left, double outer_top,
                          double content_w, double content_h,
                          bool is_child)
{
	if (!NSApp)
		return nil;
	NSArray<NSWindow *> *wins = [NSApp windows];
	if (!wins || wins.count == 0)
		return nil;

	NSScreen *primary = [[NSScreen screens] firstObject];
	CGFloat primary_h = primary ? primary.frame.size.height : 0.0;
	NSString *hint = (title_hint && title_hint[0])
		? [NSString stringWithUTF8String:title_hint] : nil;

	NSWindow *best = nil;
	double best_score = 1e18;
	for (NSWindow *w in wins) {
		if (!w || !w.contentView)
			continue;
		bool w_child = (w.parentWindow != nil);
		if (w_child != is_child)
			continue;
		if (!w.isVisible && !w.isMiniaturized)
			continue;
		NSRect wf = w.frame;
		NSSize cv = w.contentView.bounds.size;
		if (cv.width < 16.0 || cv.height < 16.0)
			continue;

		double win_left = wf.origin.x;
		double win_top = primary_h > 0.0
			? (primary_h - (wf.origin.y + wf.size.height))
			: wf.origin.y;
		double score = fabs(cv.width - content_w) * 2.0
			+ fabs(cv.height - content_h) * 2.0
			+ fabs(win_left - outer_left)
			+ fabs(win_top - outer_top);
		if (hint && w.title && [w.title isEqualToString:hint])
			score -= 1000.0;
		if (w.isKeyWindow)
			score -= 5.0;
		if (score < best_score) {
			best_score = score;
			best = w;
		}
	}
	if (!best && !is_child)
		best = [NSApp keyWindow] ?: [wins firstObject];
	return best;
}

bool
etaf_mpv_gpu_platform_available (void)
{
	@autoreleasepool {
		if (!NSApp)
			return false;
		NSArray<NSWindow *> *wins = [NSApp windows];
		return wins && wins.count > 0;
	}
}

etaf_mpv_gpu *
etaf_mpv_gpu_create (mpv_handle *mpv, const etaf_mpv_api *api)
{
	if (!mpv || !api)
		return NULL;
	@autoreleasepool {
		CGLPixelFormatAttribute attrs[] = {
			kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute) kCGLOGLPVersion_3_2_Core,
			kCGLPFAColorSize, (CGLPixelFormatAttribute) 24,
			kCGLPFAAlphaSize, (CGLPixelFormatAttribute) 8,
			kCGLPFAAccelerated,
			kCGLPFADoubleBuffer,
			kCGLPFAAllowOfflineRenderers,
			0
		};
		CGLPixelFormatObj pf = NULL;
		GLint npix = 0;
		CGLChoosePixelFormat(attrs, &pf, &npix);
		if (!pf) {
			CGLPixelFormatAttribute fallback[] = {
				kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute) kCGLOGLPVersion_3_2_Core,
				kCGLPFAAccelerated,
				kCGLPFADoubleBuffer,
				0
			};
			CGLChoosePixelFormat(fallback, &pf, &npix);
		}
		if (!pf)
			return NULL;

		CGLContextObj ctx = NULL;
		if (CGLCreateContext(pf, NULL, &ctx) != kCGLNoError || !ctx) {
			CGLReleasePixelFormat(pf);
			return NULL;
		}
		/* Never block Emacs's main thread on swap interval; CoreAnimation
		   handles display vsync compositing.  */
		GLint swap_int = 0;
		CGLSetParameter(ctx, kCGLCPSwapInterval, &swap_int);

		etaf_mpv_gpu *gpu = calloc(1, sizeof *gpu);
		if (!gpu) {
			CGLReleaseContext(ctx);
			CGLReleasePixelFormat(pf);
			return NULL;
		}
		gpu->api = api;
		gpu->mpv = mpv;
		gpu->cgl_pf = pf;
		gpu->cgl_ctx = ctx;
		atomic_init(&gpu->refcount, 1);
		atomic_init(&gpu->destroyed, 0);
		atomic_init(&gpu->visible, 0);
		atomic_init(&gpu->pending_update, 0);
		atomic_init(&gpu->force_redraw, 0);
		atomic_init(&gpu->frames, 0);

		CGLLockContext(ctx);
		CGLSetCurrentContext(ctx);
		etaf_mpv_opengl_init_params gl_init = {
			.get_proc_address = etaf_gl_get_proc_address,
			.get_proc_address_ctx = NULL
		};
		etaf_mpv_render_param params[] = {
			{ ETAF_MPV_RP_API_TYPE, (void *) "opengl" },
			{ ETAF_MPV_RP_OPENGL_INIT_PARAMS, &gl_init },
			{ ETAF_MPV_RP_INVALID, NULL }
		};
		int rc = api->render_context_create(&gpu->mpv_gl, mpv, params);
		CGLUnlockContext(ctx);

		if (rc < 0 || !gpu->mpv_gl) {
			CGLReleaseContext(ctx);
			CGLReleasePixelFormat(pf);
			free(gpu);
			return NULL;
		}

		EtafMpvGLHostView *view = [[EtafMpvGLHostView alloc] initWithFrame:NSZeroRect];
		view.gpu = gpu;
		view.autoresizingMask = NSViewNotSizable;
		view.hidden = YES;
		/* Standard layer-backed view: AppKit calls makeBackingLayer and owns
		   layer.frame automatically across all view moves and resizes.  */
		view.wantsLayer = YES;
		EtafMpvGLLayer *layer = (EtafMpvGLLayer *) view.layer;
		if (!layer || ![layer isKindOfClass:[EtafMpvGLLayer class]]) {
			CGLReleaseContext(ctx);
			CGLReleasePixelFormat(pf);
			free(gpu);
			return NULL;
		}

		gpu->host_view_ref = CFBridgingRetain(view);
		gpu->gl_layer_ref = CFBridgingRetain(layer);

		api->render_context_set_update_callback(
			gpu->mpv_gl, etaf_mpv_gpu_on_update, gpu);
		return gpu;
	}
}

bool
etaf_mpv_gpu_configure (etaf_mpv_gpu *gpu,
                        uint64_t window_id,
                        const char *title_hint,
                        double outer_left, double outer_top,
                        double content_w, double content_h,
                        bool is_child,
                        double x, double y, double w, double h,
                        bool visible)
{
	(void) window_id;
	if (!gpu || atomic_load_explicit(&gpu->destroyed, memory_order_acquire))
		return false;
	@autoreleasepool {
		EtafMpvGLHostView *view = (__bridge EtafMpvGLHostView *) gpu->host_view_ref;
		EtafMpvGLLayer *layer = (__bridge EtafMpvGLLayer *) gpu->gl_layer_ref;
		if (!view || !layer)
			return false;

		bool want_vis = visible && w >= 1.0 && h >= 1.0;
		bool prev_vis = atomic_load_explicit(&gpu->visible, memory_order_acquire) != 0;

		if (!want_vis) {
			atomic_store_explicit(&gpu->visible, 0, memory_order_release);
			if (!view.isHidden) {
				[CATransaction begin];
				[CATransaction setDisableActions:YES];
				view.hidden = YES;
				[CATransaction commit];
				[CATransaction flush];
			}
			return true;
		}

		NSWindow *win = etaf_mpv_gpu_find_window(
			title_hint, outer_left, outer_top, content_w, content_h, is_child);
		if (!win || !win.contentView) {
			atomic_store_explicit(&gpu->visible, 0, memory_order_release);
			if (!view.isHidden) {
				[CATransaction begin];
				[CATransaction setDisableActions:YES];
				view.hidden = YES;
				[CATransaction commit];
			}
			return false;
		}

		NSView *cv = win.contentView;
		CGFloat ch = cv.bounds.size.height;
		CGFloat ay = [cv isFlipped] ? (CGFloat) y : (ch - (CGFloat) y - (CGFloat) h);
		CGFloat scale = win.backingScaleFactor > 0.0 ? win.backingScaleFactor : 1.0;
		bool win_changed = (gpu->attached_win != (__bridge CFTypeRef) win)
			|| (view.superview != cv);
		bool geom_changed = !gpu->has_rect
			|| fabs(gpu->last_x - x) > 0.25
			|| fabs(gpu->last_y - ay) > 0.25
			|| fabs(gpu->last_w - w) > 0.25
			|| fabs(gpu->last_h - h) > 0.25
			|| fabs(gpu->last_scale - scale) > 0.01;

		atomic_store_explicit(&gpu->visible, 1, memory_order_release);

		if (win_changed || geom_changed || !prev_vis || view.isHidden) {
			[CATransaction begin];
			[CATransaction setDisableActions:YES];
			if (win_changed) {
				if (view.superview)
					[view removeFromSuperview];
				[cv addSubview:view positioned:NSWindowAbove relativeTo:nil];
				gpu->attached_win = (__bridge CFTypeRef) win;
			}
			view.frame = NSMakeRect((CGFloat) x, ay, (CGFloat) w, (CGFloat) h);
			layer.contentsScale = scale;
			if (win.colorSpace && win.colorSpace.CGColorSpace)
				layer.colorspace = win.colorSpace.CGColorSpace;
			view.hidden = NO;
			[CATransaction commit];

			gpu->last_x = x;
			gpu->last_y = ay;
			gpu->last_w = w;
			gpu->last_h = h;
			gpu->last_scale = scale;
			gpu->has_rect = true;

			atomic_store_explicit(&gpu->force_redraw, 1, memory_order_release);
			[layer setNeedsDisplay];
			[CATransaction flush];
		}
		return true;
	}
}

void
etaf_mpv_gpu_request_redraw (etaf_mpv_gpu *gpu)
{
	if (!gpu || atomic_load_explicit(&gpu->destroyed, memory_order_acquire))
		return;
	@autoreleasepool {
		atomic_store_explicit(&gpu->force_redraw, 1, memory_order_release);
		if (atomic_load_explicit(&gpu->visible, memory_order_acquire)) {
			EtafMpvGLLayer *layer = (__bridge EtafMpvGLLayer *) gpu->gl_layer_ref;
			if (layer) {
				[layer setNeedsDisplay];
				[CATransaction flush];
			}
		}
	}
}

uint64_t
etaf_mpv_gpu_frame_count (etaf_mpv_gpu *gpu)
{
	if (!gpu)
		return 0;
	return (uint64_t) atomic_load_explicit(&gpu->frames, memory_order_relaxed);
}

bool
etaf_mpv_gpu_grab_rgba (etaf_mpv_gpu *gpu, int width, int height, uint8_t *dst_rgba)
{
	if (!gpu || !dst_rgba || width <= 0 || height <= 0
	    || atomic_load_explicit(&gpu->destroyed, memory_order_acquire)
	    || !gpu->mpv_gl || !gpu->cgl_ctx)
		return false;

	CGLLockContext(gpu->cgl_ctx);
	CGLSetCurrentContext(gpu->cgl_ctx);

	GLuint tex = 0;
	GLuint fbo = 0;
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0,
	             GL_RGBA, GL_UNSIGNED_BYTE, NULL);

	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
	                       GL_TEXTURE_2D, tex, 0);

	bool ok = false;
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) {
		etaf_mpv_opengl_fbo mfbo = {
			.fbo = (int) fbo,
			.w = width,
			.h = height,
			.internal_format = GL_RGBA8
		};
		/* FLIP_Y = 0 places video top at OpenGL y=0 so glReadPixels reads
		   top-to-bottom rows directly for TIFF output.  */
		int flip = 0;
		int block = 0;
		etaf_mpv_render_param rparams[] = {
			{ ETAF_MPV_RP_OPENGL_FBO, &mfbo },
			{ ETAF_MPV_RP_FLIP_Y, &flip },
			{ ETAF_MPV_RP_BLOCK_FOR_TARGET_TIME, &block },
			{ ETAF_MPV_RP_INVALID, NULL }
		};
		if (gpu->api->render_context_render(gpu->mpv_gl, rparams) >= 0) {
			glBindFramebuffer(GL_FRAMEBUFFER, fbo);
			glPixelStorei(GL_PACK_ALIGNMENT, 1);
			glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, dst_rgba);
			ok = true;
		}
	}

	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	glBindTexture(GL_TEXTURE_2D, 0);
	glDeleteFramebuffers(1, &fbo);
	glDeleteTextures(1, &tex);
	CGLUnlockContext(gpu->cgl_ctx);
	return ok;
}

void
etaf_mpv_gpu_destroy (etaf_mpv_gpu *gpu)
{
	if (!gpu)
		return;
	if (atomic_exchange_explicit(&gpu->destroyed, 1, memory_order_acq_rel) != 0)
		return;
	atomic_store_explicit(&gpu->visible, 0, memory_order_release);

	@autoreleasepool {
		if (gpu->mpv_gl) {
			gpu->api->render_context_set_update_callback(gpu->mpv_gl, NULL, NULL);
			if (gpu->cgl_ctx) {
				CGLLockContext(gpu->cgl_ctx);
				CGLSetCurrentContext(gpu->cgl_ctx);
				gpu->api->render_context_free(gpu->mpv_gl);
				CGLSetCurrentContext(NULL);
				CGLUnlockContext(gpu->cgl_ctx);
			} else {
				gpu->api->render_context_free(gpu->mpv_gl);
			}
			gpu->mpv_gl = NULL;
		}

		EtafMpvGLLayer *layer = (__bridge EtafMpvGLLayer *) gpu->gl_layer_ref;
		if (layer)
			layer.gpu = NULL;

		EtafMpvGLHostView *view = (__bridge EtafMpvGLHostView *) gpu->host_view_ref;
		if (view) {
			[CATransaction begin];
			[CATransaction setDisableActions:YES];
			view.hidden = YES;
			[view removeFromSuperview];
			[CATransaction commit];
			[CATransaction flush];
		}

		if (gpu->gl_layer_ref) {
			CFRelease(gpu->gl_layer_ref);
			gpu->gl_layer_ref = NULL;
		}
		if (gpu->host_view_ref) {
			CFRelease(gpu->host_view_ref);
			gpu->host_view_ref = NULL;
		}
		gpu->attached_win = NULL;

		if (gpu->cgl_ctx) {
			CGLReleaseContext(gpu->cgl_ctx);
			gpu->cgl_ctx = NULL;
		}
		if (gpu->cgl_pf) {
			CGLReleasePixelFormat(gpu->cgl_pf);
			gpu->cgl_pf = NULL;
		}
	}
	etaf_mpv_gpu_release(gpu);
}
