/* etaf-video-mpv-win32.c --- Native Windows GPU video layer for etaf-video-mpv  -*- c-file-style: "linux" -*-

   Embeds a transparent input-pass-through Win32 child HWND backed by a WGL
   OpenGL context and libmpv's OpenGL render API directly inside the target
   Emacs frame window.  Requires no Emacs source patches or recompilation,
   routes all mouse and keyboard events straight to Emacs, runs OpenGL
   rendering on a dedicated thread so Emacs's W32 message loop never stalls,
   and supports offscreen FBO frame grabs when in-buffer ETAF modals/drawers
   occlude the video canvas.

   Copyright (C) 2026  ETAF contributors

   This file is free software: you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by the
   Free Software Foundation, either version 3 of the License, or (at your
   option) any later version.  */

#include "etaf-video-mpv-internal.h"

#include <GL/gl.h>

#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ETAF_WIN32_WNDCLASS L"EtafMpvGLOverlay"

/* WGL / OpenGL 3.0+ constants (self-contained: no glext.h/wglext.h needed).  */
#define ETAF_WGL_CONTEXT_MAJOR_VERSION_ARB    0x2091
#define ETAF_WGL_CONTEXT_MINOR_VERSION_ARB    0x2092
#define ETAF_WGL_CONTEXT_PROFILE_MASK_ARB     0x9126
#define ETAF_WGL_CONTEXT_CORE_PROFILE_BIT_ARB 0x00000001

#define ETAF_GL_FRAMEBUFFER          0x8D40
#define ETAF_GL_COLOR_ATTACHMENT0    0x8CE0
#define ETAF_GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define ETAF_GL_RGBA8                0x8058

typedef HGLRC (WINAPI *pfn_wglCreateContextAttribsARB)(HDC, HGLRC, const int *);
typedef BOOL  (WINAPI *pfn_wglSwapIntervalEXT)(int);

typedef void   (APIENTRY *pfn_glGenFramebuffers)(GLsizei, GLuint *);
typedef void   (APIENTRY *pfn_glBindFramebuffer)(GLenum, GLuint);
typedef void   (APIENTRY *pfn_glFramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
typedef GLenum (APIENTRY *pfn_glCheckFramebufferStatus)(GLenum);
typedef void   (APIENTRY *pfn_glDeleteFramebuffers)(GLsizei, const GLuint *);

struct etaf_mpv_gpu {
	const etaf_mpv_api *api;
	mpv_handle *mpv;
	mpv_render_context *mpv_gl;

	HWND hwnd;
	HWND parent_hwnd;
	HDC hdc;
	HGLRC hglrc;

	HANDLE thread;
	HANDLE init_done_event;
	HANDLE wake_event;
	HANDLE grab_done_event;
	CRITICAL_SECTION mu;

	pfn_glGenFramebuffers fn_gen_fbos;
	pfn_glBindFramebuffer fn_bind_fbo;
	pfn_glFramebufferTexture2D fn_fbo_tex2d;
	pfn_glCheckFramebufferStatus fn_check_fbo;
	pfn_glDeleteFramebuffers fn_del_fbos;

	bool init_ok;
	atomic_int destroyed;
	atomic_int visible;
	atomic_int dirty;
	atomic_int force_redraw;
	atomic_uint_fast64_t frames;

	int draw_w;
	int draw_h;

	int last_x;
	int last_y;
	int last_w;
	int last_h;
	bool has_rect;

	/* Synchronous offscreen FBO snapshot request serviced by render thread.  */
	bool grab_pending;
	bool grab_ok;
	int grab_w;
	int grab_h;
	uint8_t *grab_dst;
};

static HMODULE g_opengl32;
static INIT_ONCE g_class_once = INIT_ONCE_STATIC_INIT;

static void *
etaf_wgl_get_proc_address (void *ctx, const char *name)
{
	(void) ctx;
	if (!name)
		return NULL;
	void *p = (void *) wglGetProcAddress(name);
	uintptr_t addr = (uintptr_t) p;
	if (addr == 0 || addr == 1 || addr == 2 || addr == 3 || addr == (uintptr_t) -1) {
		if (!g_opengl32)
			g_opengl32 = GetModuleHandleA("opengl32.dll");
		if (!g_opengl32)
			g_opengl32 = LoadLibraryA("opengl32.dll");
		p = g_opengl32 ? (void *) GetProcAddress(g_opengl32, name) : NULL;
	}
	return p;
}

static LRESULT CALLBACK
etaf_win32_wndproc (HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
	switch (msg) {
	case WM_NCHITTEST:
		return HTTRANSPARENT;
	case WM_MOUSEACTIVATE:
		return MA_NOACTIVATEANDEAT;
	case WM_ERASEBKGND:
		return 1;
	case WM_PAINT: {
		PAINTSTRUCT ps;
		BeginPaint(hwnd, &ps);
		EndPaint(hwnd, &ps);
		etaf_mpv_gpu *gpu = (etaf_mpv_gpu *) GetWindowLongPtrW(hwnd, GWLP_USERDATA);
		if (gpu && !atomic_load_explicit(&gpu->destroyed, memory_order_acquire))
			etaf_mpv_gpu_request_redraw(gpu);
		return 0;
	}
	default:
		return DefWindowProcW(hwnd, msg, wp, lp);
	}
}

static BOOL CALLBACK
etaf_win32_register_class_cb (PINIT_ONCE once, PVOID param, PVOID *ctx)
{
	(void) once; (void) param; (void) ctx;
	WNDCLASSEXW wc;
	memset(&wc, 0, sizeof wc);
	wc.cbSize = sizeof wc;
	wc.style = CS_OWNDC | CS_HREDRAW | CS_VREDRAW;
	wc.lpfnWndProc = etaf_win32_wndproc;
	wc.hInstance = GetModuleHandleW(NULL);
	wc.lpszClassName = ETAF_WIN32_WNDCLASS;
	RegisterClassExW(&wc);
	return TRUE;
}

static void
etaf_win32_ensure_class (void)
{
	InitOnceExecuteOnce(&g_class_once, etaf_win32_register_class_cb, NULL, NULL);
}

static bool
etaf_win32_is_own_window (HWND hwnd)
{
	if (!hwnd || !IsWindow(hwnd))
		return false;
	DWORD pid = 0;
	GetWindowThreadProcessId(hwnd, &pid);
	if (pid != GetCurrentProcessId())
		return false;
	WCHAR cls[64];
	if (GetClassNameW(hwnd, cls, 64) > 0 && wcscmp(cls, ETAF_WIN32_WNDCLASS) == 0)
		return false;
	return true;
}

typedef struct {
	DWORD pid;
	const WCHAR *title_hint;
	double outer_left;
	double outer_top;
	double content_w;
	double content_h;
	bool is_child;
	bool any_visible;
	HWND best;
	double best_score;
} etaf_win32_enum_ctx;

static BOOL CALLBACK
etaf_win32_enum_cb (HWND hwnd, LPARAM lp)
{
	etaf_win32_enum_ctx *ec = (etaf_win32_enum_ctx *) lp;
	DWORD pid = 0;
	GetWindowThreadProcessId(hwnd, &pid);
	if (pid != ec->pid)
		return TRUE;
	if (!IsWindowVisible(hwnd) && !IsIconic(hwnd))
		return TRUE;
	WCHAR cls[64];
	if (GetClassNameW(hwnd, cls, 64) > 0 && wcscmp(cls, ETAF_WIN32_WNDCLASS) == 0)
		return TRUE;

	RECT cr, wr;
	if (!GetClientRect(hwnd, &cr) || !GetWindowRect(hwnd, &wr))
		return TRUE;
	int cw = cr.right - cr.left;
	int ch = cr.bottom - cr.top;
	if (cw < 16 || ch < 16)
		return TRUE;

	ec->any_visible = true;
	bool w_child = (GetWindow(hwnd, GW_OWNER) != NULL)
		|| ((GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_CHILD) != 0);
	if (ec->content_w <= 0.0 && ec->content_h <= 0.0) {
		if (!ec->best || hwnd == GetActiveWindow() || hwnd == GetForegroundWindow())
			ec->best = hwnd;
		return TRUE;
	}

	double score = fabs((double) cw - ec->content_w) * 2.0
		+ fabs((double) ch - ec->content_h) * 2.0
		+ fabs((double) wr.left - ec->outer_left)
		+ fabs((double) wr.top - ec->outer_top);
	if (w_child != ec->is_child)
		score += 500.0;
	if (ec->title_hint && ec->title_hint[0]) {
		WCHAR title[512];
		if (GetWindowTextW(hwnd, title, 512) > 0 && wcscmp(title, ec->title_hint) == 0)
			score -= 1000.0;
	}
	if (hwnd == GetForegroundWindow() || hwnd == GetActiveWindow())
		score -= 5.0;
	if (score < ec->best_score) {
		ec->best_score = score;
		ec->best = hwnd;
	}
	return TRUE;
}

static HWND
etaf_win32_find_window (uint64_t window_id,
                        const char *title_hint,
                        double outer_left, double outer_top,
                        double content_w, double content_h,
                        bool is_child)
{
	if (window_id != 0) {
		HWND h = (HWND) (uintptr_t) window_id;
		if (etaf_win32_is_own_window(h))
			return h;
	}
	WCHAR wtitle[512];
	wtitle[0] = L'\0';
	if (title_hint && title_hint[0]) {
		MultiByteToWideChar(CP_UTF8, 0, title_hint, -1, wtitle, 512);
		wtitle[511] = L'\0';
	}
	etaf_win32_enum_ctx ec;
	memset(&ec, 0, sizeof ec);
	ec.pid = GetCurrentProcessId();
	ec.title_hint = wtitle[0] ? wtitle : NULL;
	ec.outer_left = outer_left;
	ec.outer_top = outer_top;
	ec.content_w = content_w;
	ec.content_h = content_h;
	ec.is_child = is_child;
	ec.best_score = 1e18;
	EnumWindows(etaf_win32_enum_cb, (LPARAM) &ec);
	return ec.best;
}

static void
etaf_win32_on_update (void *cb_ctx)
{
	etaf_mpv_gpu *gpu = (etaf_mpv_gpu *) cb_ctx;
	if (!gpu || atomic_load_explicit(&gpu->destroyed, memory_order_acquire))
		return;
	atomic_store_explicit(&gpu->dirty, 1, memory_order_release);
	SetEvent(gpu->wake_event);
}

static bool
etaf_win32_do_grab_rgba (etaf_mpv_gpu *gpu, int width, int height, uint8_t *dst_rgba)
{
	if (!gpu->mpv_gl || !dst_rgba || width <= 0 || height <= 0
	    || !gpu->fn_gen_fbos || !gpu->fn_bind_fbo || !gpu->fn_fbo_tex2d
	    || !gpu->fn_check_fbo || !gpu->fn_del_fbos)
		return false;

	GLuint tex = 0;
	GLuint fbo = 0;
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexImage2D(GL_TEXTURE_2D, 0, ETAF_GL_RGBA8, width, height, 0,
	             GL_RGBA, GL_UNSIGNED_BYTE, NULL);

	gpu->fn_gen_fbos(1, &fbo);
	gpu->fn_bind_fbo(ETAF_GL_FRAMEBUFFER, fbo);
	gpu->fn_fbo_tex2d(ETAF_GL_FRAMEBUFFER, ETAF_GL_COLOR_ATTACHMENT0,
	                  GL_TEXTURE_2D, tex, 0);

	bool ok = false;
	if (gpu->fn_check_fbo(ETAF_GL_FRAMEBUFFER) == ETAF_GL_FRAMEBUFFER_COMPLETE) {
		etaf_mpv_opengl_fbo mfbo = {
			.fbo = (int) fbo,
			.w = width,
			.h = height,
			.internal_format = ETAF_GL_RGBA8
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
			gpu->fn_bind_fbo(ETAF_GL_FRAMEBUFFER, fbo);
			glPixelStorei(GL_PACK_ALIGNMENT, 1);
			glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, dst_rgba);
			ok = true;
		}
	}

	gpu->fn_bind_fbo(ETAF_GL_FRAMEBUFFER, 0);
	glBindTexture(GL_TEXTURE_2D, 0);
	gpu->fn_del_fbos(1, &fbo);
	glDeleteTextures(1, &tex);
	return ok;
}

static DWORD WINAPI
etaf_win32_render_thread (LPVOID arg)
{
	etaf_mpv_gpu *gpu = (etaf_mpv_gpu *) arg;

	HGLRC temp_rc = wglCreateContext(gpu->hdc);
	if (!temp_rc) {
		gpu->init_ok = false;
		SetEvent(gpu->init_done_event);
		return 1;
	}
	if (!wglMakeCurrent(gpu->hdc, temp_rc)) {
		wglDeleteContext(temp_rc);
		gpu->init_ok = false;
		SetEvent(gpu->init_done_event);
		return 1;
	}

	HGLRC final_rc = temp_rc;
	pfn_wglCreateContextAttribsARB create_attribs =
		(pfn_wglCreateContextAttribsARB) (void *) wglGetProcAddress("wglCreateContextAttribsARB");
	if (create_attribs) {
		static const int attrs[] = {
			ETAF_WGL_CONTEXT_MAJOR_VERSION_ARB, 3,
			ETAF_WGL_CONTEXT_MINOR_VERSION_ARB, 2,
			ETAF_WGL_CONTEXT_PROFILE_MASK_ARB, ETAF_WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
			0
		};
		HGLRC core_rc = create_attribs(gpu->hdc, NULL, attrs);
		if (core_rc) {
			if (wglMakeCurrent(gpu->hdc, core_rc)) {
				wglDeleteContext(temp_rc);
				final_rc = core_rc;
			} else {
				wglDeleteContext(core_rc);
				wglMakeCurrent(gpu->hdc, temp_rc);
			}
		}
	}
	gpu->hglrc = final_rc;

	/* Never block SwapBuffers on vsync inside the video worker; libmpv paces
	   its own frame update notifications to the audio clock.  */
	pfn_wglSwapIntervalEXT swap_interval =
		(pfn_wglSwapIntervalEXT) (void *) wglGetProcAddress("wglSwapIntervalEXT");
	if (swap_interval)
		swap_interval(0);

	gpu->fn_gen_fbos  = (pfn_glGenFramebuffers) etaf_wgl_get_proc_address(NULL, "glGenFramebuffers");
	gpu->fn_bind_fbo  = (pfn_glBindFramebuffer) etaf_wgl_get_proc_address(NULL, "glBindFramebuffer");
	gpu->fn_fbo_tex2d = (pfn_glFramebufferTexture2D) etaf_wgl_get_proc_address(NULL, "glFramebufferTexture2D");
	gpu->fn_check_fbo = (pfn_glCheckFramebufferStatus) etaf_wgl_get_proc_address(NULL, "glCheckFramebufferStatus");
	gpu->fn_del_fbos  = (pfn_glDeleteFramebuffers) etaf_wgl_get_proc_address(NULL, "glDeleteFramebuffers");

	etaf_mpv_opengl_init_params gl_init = {
		.get_proc_address = etaf_wgl_get_proc_address,
		.get_proc_address_ctx = NULL
	};
	etaf_mpv_render_param params[] = {
		{ ETAF_MPV_RP_API_TYPE, (void *) "opengl" },
		{ ETAF_MPV_RP_OPENGL_INIT_PARAMS, &gl_init },
		{ ETAF_MPV_RP_INVALID, NULL }
	};
	int rc = gpu->api->render_context_create(&gpu->mpv_gl, gpu->mpv, params);
	if (rc < 0 || !gpu->mpv_gl) {
		wglMakeCurrent(NULL, NULL);
		wglDeleteContext(gpu->hglrc);
		gpu->hglrc = NULL;
		gpu->init_ok = false;
		SetEvent(gpu->init_done_event);
		return 1;
	}

	glClearColor(5.0f / 255.0f, 6.0f / 255.0f, 7.0f / 255.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	SwapBuffers(gpu->hdc);

	gpu->api->render_context_set_update_callback(gpu->mpv_gl, etaf_win32_on_update, gpu);
	gpu->init_ok = true;
	SetEvent(gpu->init_done_event);

	for (;;) {
		WaitForSingleObject(gpu->wake_event, 100);
		if (atomic_load_explicit(&gpu->destroyed, memory_order_acquire))
			break;

		bool do_grab = false;
		int gw = 0, gh = 0;
		uint8_t *gdst = NULL;
		int dw = 0, dh = 0;

		EnterCriticalSection(&gpu->mu);
		if (gpu->grab_pending) {
			do_grab = true;
			gw = gpu->grab_w;
			gh = gpu->grab_h;
			gdst = gpu->grab_dst;
			gpu->grab_pending = false;
		}
		dw = gpu->draw_w;
		dh = gpu->draw_h;
		LeaveCriticalSection(&gpu->mu);

		if (do_grab) {
			bool ok = etaf_win32_do_grab_rgba(gpu, gw, gh, gdst);
			EnterCriticalSection(&gpu->mu);
			gpu->grab_ok = ok;
			LeaveCriticalSection(&gpu->mu);
			SetEvent(gpu->grab_done_event);
		}

		int was_dirty = atomic_exchange_explicit(&gpu->dirty, 0, memory_order_acq_rel);
		int force = atomic_exchange_explicit(&gpu->force_redraw, 0, memory_order_acq_rel);
		if (!was_dirty && !force)
			continue;

		bool vis = atomic_load_explicit(&gpu->visible, memory_order_acquire) != 0;
		uint64_t flags = gpu->api->render_context_update(gpu->mpv_gl);
		if (vis && dw > 0 && dh > 0) {
			if ((flags & ETAF_MPV_RENDER_UPDATE_FRAME) || force) {
				etaf_mpv_opengl_fbo mfbo = {
					.fbo = 0,
					.w = dw,
					.h = dh,
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
				if (gpu->api->render_context_render(gpu->mpv_gl, rparams) >= 0) {
					SwapBuffers(gpu->hdc);
					gpu->api->render_context_report_swap(gpu->mpv_gl);
					atomic_fetch_add_explicit(&gpu->frames, 1, memory_order_relaxed);
				}
			}
		} else if (flags & ETAF_MPV_RENDER_UPDATE_FRAME) {
			/* Hidden/occluded: drain frame notifications with zero GPU draw
			   so audio clocks and decoder queues stay healthy.  */
			int skip = 1;
			int block = 0;
			etaf_mpv_render_param rparams[] = {
				{ ETAF_MPV_RP_SKIP_RENDERING, &skip },
				{ ETAF_MPV_RP_BLOCK_FOR_TARGET_TIME, &block },
				{ ETAF_MPV_RP_INVALID, NULL }
			};
			if (gpu->api->render_context_render(gpu->mpv_gl, rparams) >= 0) {
				gpu->api->render_context_report_swap(gpu->mpv_gl);
				atomic_fetch_add_explicit(&gpu->frames, 1, memory_order_relaxed);
			}
		}
	}

	if (gpu->mpv_gl) {
		gpu->api->render_context_set_update_callback(gpu->mpv_gl, NULL, NULL);
		gpu->api->render_context_free(gpu->mpv_gl);
		gpu->mpv_gl = NULL;
	}
	wglMakeCurrent(NULL, NULL);
	if (gpu->hglrc) {
		wglDeleteContext(gpu->hglrc);
		gpu->hglrc = NULL;
	}
	return 0;
}

bool
etaf_mpv_gpu_platform_available (void)
{
	etaf_win32_enum_ctx ec;
	memset(&ec, 0, sizeof ec);
	ec.pid = GetCurrentProcessId();
	ec.best_score = 1e18;
	EnumWindows(etaf_win32_enum_cb, (LPARAM) &ec);
	return ec.any_visible;
}

etaf_mpv_gpu *
etaf_mpv_gpu_create (mpv_handle *mpv, const etaf_mpv_api *api)
{
	if (!mpv || !api)
		return NULL;

	HWND owner = etaf_win32_find_window(0, NULL, 0, 0, 0, 0, false);
	if (!owner)
		return NULL;

	etaf_win32_ensure_class();

	etaf_mpv_gpu *gpu = calloc(1, sizeof *gpu);
	if (!gpu)
		return NULL;

	gpu->api = api;
	gpu->mpv = mpv;
	gpu->parent_hwnd = owner;
	atomic_init(&gpu->destroyed, 0);
	atomic_init(&gpu->visible, 0);
	atomic_init(&gpu->dirty, 0);
	atomic_init(&gpu->force_redraw, 0);
	atomic_init(&gpu->frames, 0);
	InitializeCriticalSection(&gpu->mu);

	gpu->init_done_event = CreateEventW(NULL, TRUE, FALSE, NULL);
	gpu->wake_event      = CreateEventW(NULL, FALSE, FALSE, NULL);
	gpu->grab_done_event = CreateEventW(NULL, FALSE, FALSE, NULL);
	if (!gpu->init_done_event || !gpu->wake_event || !gpu->grab_done_event)
		goto fail;

	gpu->hwnd = CreateWindowExW(
		WS_EX_NOACTIVATE | WS_EX_NOPARENTNOTIFY,
		ETAF_WIN32_WNDCLASS, L"",
		WS_CHILD | WS_CLIPSIBLINGS | WS_DISABLED,
		0, 0, 1, 1,
		owner, NULL, GetModuleHandleW(NULL), NULL);
	if (!gpu->hwnd)
		goto fail;

	SetWindowLongPtrW(gpu->hwnd, GWLP_USERDATA, (LONG_PTR) gpu);
	gpu->hdc = GetDC(gpu->hwnd);
	if (!gpu->hdc)
		goto fail;

	PIXELFORMATDESCRIPTOR pfd;
	memset(&pfd, 0, sizeof pfd);
	pfd.nSize = sizeof pfd;
	pfd.nVersion = 1;
	pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
	pfd.iPixelType = PFD_TYPE_RGBA;
	pfd.cColorBits = 24;
	pfd.cAlphaBits = 8;
	pfd.iLayerType = PFD_MAIN_PLANE;

	int pf = ChoosePixelFormat(gpu->hdc, &pfd);
	if (pf == 0 || !SetPixelFormat(gpu->hdc, pf, &pfd))
		goto fail;

	gpu->thread = CreateThread(NULL, 0, etaf_win32_render_thread, gpu, 0, NULL);
	if (!gpu->thread)
		goto fail;

	WaitForSingleObject(gpu->init_done_event, 5000);
	if (!gpu->init_ok)
		goto fail;

	return gpu;

fail:
	etaf_mpv_gpu_destroy(gpu);
	return NULL;
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
	if (!gpu || !gpu->hwnd || atomic_load_explicit(&gpu->destroyed, memory_order_acquire))
		return false;

	bool want_vis = visible && w >= 1.0 && h >= 1.0;
	bool prev_vis = atomic_load_explicit(&gpu->visible, memory_order_acquire) != 0;

	if (!want_vis) {
		atomic_store_explicit(&gpu->visible, 0, memory_order_release);
		if (IsWindowVisible(gpu->hwnd))
			ShowWindow(gpu->hwnd, SW_HIDE);
		SetEvent(gpu->wake_event);
		return true;
	}

	HWND parent = etaf_win32_find_window(
		window_id, title_hint, outer_left, outer_top, content_w, content_h, is_child);
	if (!parent) {
		atomic_store_explicit(&gpu->visible, 0, memory_order_release);
		if (IsWindowVisible(gpu->hwnd))
			ShowWindow(gpu->hwnd, SW_HIDE);
		return false;
	}

	/* Exclude our visible child rect from Emacs's GDI paints to avoid flicker.  */
	LONG_PTR pstyle = GetWindowLongPtrW(parent, GWL_STYLE);
	if (!(pstyle & WS_CLIPCHILDREN))
		SetWindowLongPtrW(parent, GWL_STYLE, pstyle | WS_CLIPCHILDREN);

	/* Auto-calibrate DPI scaling if Emacs reports logical rather than client pixels.  */
	RECT cr;
	double sx = 1.0, sy = 1.0;
	if (GetClientRect(parent, &cr)) {
		double cw = (double) (cr.right - cr.left);
		double ch = (double) (cr.bottom - cr.top);
		if (content_w > 16.0 && cw > 16.0) {
			double rx = cw / content_w;
			if (fabs(rx - 1.0) >= 0.08 && rx >= 0.5 && rx <= 4.0)
				sx = rx;
		}
		if (content_h > 16.0 && ch > 16.0) {
			double ry = ch / content_h;
			if (fabs(ry - 1.0) >= 0.08 && ry >= 0.5 && ry <= 4.0)
				sy = ry;
		}
	}

	int px = (int) llround(x * sx);
	int py = (int) llround(y * sy);
	int pw = (int) llround(w * sx);
	int ph = (int) llround(h * sy);
	if (pw < 1 || ph < 1) {
		atomic_store_explicit(&gpu->visible, 0, memory_order_release);
		if (IsWindowVisible(gpu->hwnd))
			ShowWindow(gpu->hwnd, SW_HIDE);
		return true;
	}

	bool parent_changed = (parent != gpu->parent_hwnd) || (GetParent(gpu->hwnd) != parent);
	bool geom_changed = !gpu->has_rect
		|| gpu->last_x != px || gpu->last_y != py
		|| gpu->last_w != pw || gpu->last_h != ph;

	if (parent_changed) {
		SetParent(gpu->hwnd, parent);
		gpu->parent_hwnd = parent;
	}

	EnterCriticalSection(&gpu->mu);
	gpu->draw_w = pw;
	gpu->draw_h = ph;
	LeaveCriticalSection(&gpu->mu);
	atomic_store_explicit(&gpu->visible, 1, memory_order_release);

	if (parent_changed || geom_changed || !prev_vis || !IsWindowVisible(gpu->hwnd)) {
		SetWindowPos(gpu->hwnd, HWND_TOP, px, py, pw, ph,
		             SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOCOPYBITS);
		gpu->last_x = px;
		gpu->last_y = py;
		gpu->last_w = pw;
		gpu->last_h = ph;
		gpu->has_rect = true;
		atomic_store_explicit(&gpu->force_redraw, 1, memory_order_release);
		SetEvent(gpu->wake_event);
	}
	return true;
}

void
etaf_mpv_gpu_request_redraw (etaf_mpv_gpu *gpu)
{
	if (!gpu || atomic_load_explicit(&gpu->destroyed, memory_order_acquire))
		return;
	atomic_store_explicit(&gpu->force_redraw, 1, memory_order_release);
	SetEvent(gpu->wake_event);
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
	    || !gpu->thread)
		return false;

	EnterCriticalSection(&gpu->mu);
	gpu->grab_w = width;
	gpu->grab_h = height;
	gpu->grab_dst = dst_rgba;
	gpu->grab_ok = false;
	gpu->grab_pending = true;
	LeaveCriticalSection(&gpu->mu);

	ResetEvent(gpu->grab_done_event);
	SetEvent(gpu->wake_event);
	if (WaitForSingleObject(gpu->grab_done_event, 1500) != WAIT_OBJECT_0)
		return false;

	bool ok;
	EnterCriticalSection(&gpu->mu);
	ok = gpu->grab_ok;
	gpu->grab_dst = NULL;
	LeaveCriticalSection(&gpu->mu);
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

	if (gpu->wake_event)
		SetEvent(gpu->wake_event);
	if (gpu->thread) {
		WaitForSingleObject(gpu->thread, 4000);
		CloseHandle(gpu->thread);
		gpu->thread = NULL;
	}
	if (gpu->hwnd) {
		SetWindowLongPtrW(gpu->hwnd, GWLP_USERDATA, 0);
		if (gpu->hdc) {
			ReleaseDC(gpu->hwnd, gpu->hdc);
			gpu->hdc = NULL;
		}
		DestroyWindow(gpu->hwnd);
		gpu->hwnd = NULL;
	}
	if (gpu->grab_done_event) {
		CloseHandle(gpu->grab_done_event);
		gpu->grab_done_event = NULL;
	}
	if (gpu->wake_event) {
		CloseHandle(gpu->wake_event);
		gpu->wake_event = NULL;
	}
	if (gpu->init_done_event) {
		CloseHandle(gpu->init_done_event);
		gpu->init_done_event = NULL;
	}
	DeleteCriticalSection(&gpu->mu);
	free(gpu);
}
