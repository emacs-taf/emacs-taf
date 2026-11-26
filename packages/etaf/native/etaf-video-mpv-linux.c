/* etaf-video-mpv-linux.c --- Native Linux GPU video layer (X11 & Wayland)  -*- c-file-style: "linux" -*-

   Embeds a hardware-accelerated OpenGL video surface backed by libmpv's OpenGL
   render API directly inside the target Emacs frame on Linux without requiring
   Emacs patches, recompilation, or any X11/Wayland/EGL/GTK development headers
   at compile time (all platform libraries are resolved dynamically at runtime).

   Supports two runtime backends automatically:
   1. X11 (classic X11 Emacs via `window-id', and PGTK Emacs running on X11 via
      in-process GDK X11 lookup): creates a borderless child X11 Window with an
      empty XShape ShapeInput region so all pointer/keyboard events pass straight
      to Emacs, rendered via EGL (with GLX fallback) on a dedicated render thread.
   2. Wayland (native PGTK Emacs): resolves Emacs's in-process GtkWindow,
      wl_display and wl_surface via GDK3, creates a desynchronized wl_subsurface
      with an empty wl_region input mask for full input pass-through, and renders
      via wl_egl_window + EGL on a dedicated render thread.

   Copyright (C) 2026  ETAF contributors

   This file is free software: you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by the
   Free Software Foundation, either version 3 of the License, or (at your
   option) any later version.  */

#define _GNU_SOURCE
#include "etaf-video-mpv-internal.h"

#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* -------------------------------------------------------------------------
   Minimal self-contained ABI declarations (zero -dev header dependencies)
   ------------------------------------------------------------------------- */

typedef unsigned long XID;
typedef XID Window;
typedef XID Colormap;
typedef XID Pixmap;
typedef int XBool;
typedef struct _XDisplay Display;

typedef struct {
	void *ext_data;
	unsigned long visualid;
	int c_class;
	unsigned long red_mask, green_mask, blue_mask;
	int bits_per_rgb;
	int map_entries;
} XVisual;

typedef struct {
	XVisual *visual;
	unsigned long visualid;
	int screen;
	int depth;
	int c_class;
	unsigned long red_mask, green_mask, blue_mask;
	int colormap_size;
	int bits_per_rgb;
} XVisualInfo;

typedef struct {
	Pixmap background_pixmap;
	unsigned long background_pixel;
	Pixmap border_pixmap;
	unsigned long border_pixel;
	int bit_gravity;
	int win_gravity;
	int backing_store;
	unsigned long backing_planes;
	unsigned long backing_pixel;
	XBool save_under;
	long event_mask;
	long do_not_propagate_mask;
	XBool override_redirect;
	Colormap colormap;
	XID cursor;
} XSetWindowAttributes;

typedef struct {
	short x, y;
	unsigned short width, height;
} XRectangle;

#define ETAF_X11_NONE           0L
#define ETAF_X11_INPUT_OUTPUT   1
#define ETAF_X11_ALLOC_NONE     0
#define ETAF_X11_CW_BACK_PIXMAP (1UL << 0)
#define ETAF_X11_CW_BORDER_PIX  (1UL << 3)
#define ETAF_X11_CW_COLORMAP    (1UL << 13)
#define ETAF_X11_VISUAL_ID_MASK 0x1L
#define ETAF_X11_SHAPE_SET      0
#define ETAF_X11_SHAPE_INPUT    2

/* EGL ABI */
typedef void *EGLDisplay;
typedef void *EGLConfig;
typedef void *EGLSurface;
typedef void *EGLContext;
typedef unsigned int EGLBoolean;
typedef unsigned int EGLenum;
typedef int32_t EGLint;
typedef intptr_t EGLAttrib;

#define ETAF_EGL_NO_DISPLAY  ((EGLDisplay) 0)
#define ETAF_EGL_NO_CONTEXT  ((EGLContext) 0)
#define ETAF_EGL_NO_SURFACE  ((EGLSurface) 0)
#define ETAF_EGL_SURFACE_TYPE                 0x3033
#define ETAF_EGL_WINDOW_BIT                   0x0004
#define ETAF_EGL_RENDERABLE_TYPE              0x3040
#define ETAF_EGL_OPENGL_BIT                   0x0008
#define ETAF_EGL_OPENGL_ES2_BIT               0x0004
#define ETAF_EGL_OPENGL_API                   0x30A2
#define ETAF_EGL_OPENGL_ES_API                0x30A0
#define ETAF_EGL_RED_SIZE                     0x3024
#define ETAF_EGL_GREEN_SIZE                   0x3023
#define ETAF_EGL_BLUE_SIZE                    0x3022
#define ETAF_EGL_ALPHA_SIZE                   0x3021
#define ETAF_EGL_NATIVE_VISUAL_ID             0x302E
#define ETAF_EGL_NONE                         0x3038
#define ETAF_EGL_CONTEXT_MAJOR_VERSION        0x3098
#define ETAF_EGL_CONTEXT_MINOR_VERSION        0x30FB
#define ETAF_EGL_CONTEXT_OPENGL_PROFILE_MASK  0x30FD
#define ETAF_EGL_CONTEXT_OPENGL_CORE_BIT      0x00000001
#define ETAF_EGL_PLATFORM_X11_KHR             0x31D5
#define ETAF_EGL_PLATFORM_WAYLAND_KHR         0x31D8

/* GLX ABI */
typedef void *GLXFBConfig;
typedef void *GLXContext;
typedef XID GLXDrawable;

#define ETAF_GLX_DOUBLEBUFFER             5
#define ETAF_GLX_RED_SIZE                 8
#define ETAF_GLX_GREEN_SIZE               9
#define ETAF_GLX_BLUE_SIZE                10
#define ETAF_GLX_ALPHA_SIZE               11
#define ETAF_GLX_X_VISUAL_TYPE            0x22
#define ETAF_GLX_DRAWABLE_TYPE            0x8010
#define ETAF_GLX_RENDER_TYPE              0x8011
#define ETAF_GLX_X_RENDERABLE             0x8012
#define ETAF_GLX_WINDOW_BIT               0x00000001
#define ETAF_GLX_RGBA_BIT                 0x00000001
#define ETAF_GLX_TRUE_COLOR               0x8002
#define ETAF_GLX_CONTEXT_MAJOR_ARB        0x2091
#define ETAF_GLX_CONTEXT_MINOR_ARB        0x2092
#define ETAF_GLX_CONTEXT_PROFILE_MASK_ARB 0x9126
#define ETAF_GLX_CONTEXT_CORE_BIT_ARB     0x00000001

/* OpenGL ABI */
typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
typedef float GLfloat;
typedef unsigned int GLbitfield;

#define ETAF_GL_COLOR_BUFFER_BIT     0x00004000
#define ETAF_GL_TEXTURE_2D           0x0DE1
#define ETAF_GL_TEXTURE_MAG_FILTER   0x2800
#define ETAF_GL_TEXTURE_MIN_FILTER   0x2801
#define ETAF_GL_LINEAR               0x2601
#define ETAF_GL_RGBA                 0x1908
#define ETAF_GL_RGBA8                0x8058
#define ETAF_GL_UNSIGNED_BYTE        0x1401
#define ETAF_GL_PACK_ALIGNMENT       0x0D05
#define ETAF_GL_FRAMEBUFFER          0x8D40
#define ETAF_GL_COLOR_ATTACHMENT0    0x8CE0
#define ETAF_GL_FRAMEBUFFER_COMPLETE 0x8CD5

/* GLib / GTK3 / GDK3 ABI */
typedef struct GList {
	void *data;
	struct GList *next;
	struct GList *prev;
} GList;

/* Wayland client ABI */
struct wl_display;
struct wl_proxy;
struct wl_egl_window;

struct wl_interface {
	const char *name;
	int version;
	int method_count;
	const void *methods;
	int event_count;
	const void *events;
};

struct wl_registry_listener {
	void (*global)(void *data, struct wl_proxy *reg, uint32_t name,
	               const char *interface, uint32_t version);
	void (*global_remove)(void *data, struct wl_proxy *reg, uint32_t name);
};

/* -------------------------------------------------------------------------
   Dynamically loaded symbol tables
   ------------------------------------------------------------------------- */

typedef struct {
	int loaded;
	void *x11;
	void *xext;
	void *egl;
	void *glx;
	void *gl;
	void *wl_client;
	void *wl_egl;
	void *gtk;
	void *gdk;
	void *glib;
	void *gobject;

	/* X11 */
	Display *(*XOpenDisplay)(const char *);
	int (*XCloseDisplay)(Display *);
	int (*XDefaultScreen)(Display *);
	Window (*XRootWindow)(Display *, int);
	XVisualInfo *(*XGetVisualInfo)(Display *, long, XVisualInfo *, int *);
	Colormap (*XCreateColormap)(Display *, Window, XVisual *, int);
	int (*XFreeColormap)(Display *, Colormap);
	Window (*XCreateWindow)(Display *, Window, int, int, unsigned int, unsigned int,
	                        unsigned int, int, unsigned int, XVisual *,
	                        unsigned long, XSetWindowAttributes *);
	int (*XDestroyWindow)(Display *, Window);
	int (*XMoveResizeWindow)(Display *, Window, int, int, unsigned int, unsigned int);
	int (*XMapWindow)(Display *, Window);
	int (*XUnmapWindow)(Display *, Window);
	int (*XRaiseWindow)(Display *, Window);
	int (*XFlush)(Display *);
	int (*XSync)(Display *, XBool);
	int (*XFree)(void *);
	int (*XGetGeometry)(Display *, XID, Window *, int *, int *,
	                    unsigned int *, unsigned int *, unsigned int *, unsigned int *);
	int (*XReparentWindow)(Display *, Window, Window, int, int);

	/* XShape */
	void (*XShapeCombineRectangles)(Display *, Window, int, int, int,
	                                XRectangle *, int, int, int);

	/* EGL */
	EGLDisplay (*eglGetDisplay)(void *);
	EGLDisplay (*eglGetPlatformDisplay)(EGLenum, void *, const EGLAttrib *);
	EGLBoolean (*eglInitialize)(EGLDisplay, EGLint *, EGLint *);
	EGLBoolean (*eglTerminate)(EGLDisplay);
	EGLBoolean (*eglBindAPI)(EGLenum);
	EGLBoolean (*eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
	EGLBoolean (*eglGetConfigAttrib)(EGLDisplay, EGLConfig, EGLint, EGLint *);
	EGLSurface (*eglCreateWindowSurface)(EGLDisplay, EGLConfig, uintptr_t, const EGLint *);
	EGLBoolean (*eglDestroySurface)(EGLDisplay, EGLSurface);
	EGLContext (*eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
	EGLBoolean (*eglDestroyContext)(EGLDisplay, EGLContext);
	EGLBoolean (*eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
	EGLBoolean (*eglSwapBuffers)(EGLDisplay, EGLSurface);
	EGLBoolean (*eglSwapInterval)(EGLDisplay, EGLint);
	void *(*eglGetProcAddress)(const char *);

	/* GLX */
	GLXFBConfig *(*glXChooseFBConfig)(Display *, int, const int *, int *);
	XVisualInfo *(*glXGetVisualFromFBConfig)(Display *, GLXFBConfig);
	GLXContext (*glXCreateNewContext)(Display *, GLXFBConfig, int, GLXContext, XBool);
	XBool (*glXMakeCurrent)(Display *, GLXDrawable, GLXContext);
	void (*glXDestroyContext)(Display *, GLXContext);
	void (*glXSwapBuffers)(Display *, GLXDrawable);
	void *(*glXGetProcAddressARB)(const unsigned char *);

	/* GTK3 / GDK3 / GLib (in-process only, resolved via RTLD_NOLOAD / RTLD_DEFAULT) */
	GList *(*gtk_window_list_toplevels)(void);
	const char *(*gtk_window_get_title)(void *);
	int (*gtk_widget_get_visible)(void *);
	int (*gtk_widget_get_allocated_width)(void *);
	int (*gtk_widget_get_allocated_height)(void *);
	void *(*gtk_widget_get_window)(void *);
	int (*gtk_widget_get_has_window)(void *);
	int (*gtk_widget_translate_coordinates)(void *, void *, int, int, int *, int *);
	GList *(*gtk_container_get_children)(void *);
	uintptr_t (*gtk_container_get_type)(void);
	int (*gtk_window_is_active)(void *);
	void *(*gtk_window_get_transient_for)(void *);
	void *(*gdk_window_get_display)(void *);
	int (*gdk_window_get_scale_factor)(void *);
	void (*g_list_free)(GList *);
	const char *(*g_type_name)(uintptr_t);
	int (*g_type_check_instance_is_a)(void *, uintptr_t);
	unsigned long (*gdk_x11_window_get_xid)(void *);
	struct wl_display *(*gdk_wayland_display_get_wl_display)(void *);
	struct wl_proxy *(*gdk_wayland_window_get_wl_surface)(void *);

	/* Wayland client & EGL */
	int (*wl_display_roundtrip)(struct wl_display *);
	int (*wl_display_flush)(struct wl_display *);
	int (*wl_proxy_add_listener)(struct wl_proxy *, void (**)(void), void *);
	void (*wl_proxy_destroy)(struct wl_proxy *);
	void (*wl_proxy_marshal)(struct wl_proxy *, uint32_t, ...);
	struct wl_proxy *(*wl_proxy_marshal_constructor)(
		struct wl_proxy *, uint32_t, const struct wl_interface *, ...);
	struct wl_proxy *(*wl_proxy_marshal_constructor_versioned)(
		struct wl_proxy *, uint32_t, const struct wl_interface *, uint32_t, ...);
	const struct wl_interface *wl_registry_iface;
	const struct wl_interface *wl_compositor_iface;
	const struct wl_interface *wl_subcompositor_iface;
	const struct wl_interface *wl_surface_iface;
	const struct wl_interface *wl_subsurface_iface;
	const struct wl_interface *wl_region_iface;

	struct wl_egl_window *(*wl_egl_window_create)(struct wl_proxy *, int, int);
	void (*wl_egl_window_resize)(struct wl_egl_window *, int, int, int, int);
	void (*wl_egl_window_destroy)(struct wl_egl_window *);
} etaf_linux_libs;

static etaf_linux_libs g_lx;

static void *
lx_dlopen_any (const char *const *names)
{
	for (int i = 0; names[i]; i++) {
		void *h = dlopen(names[i], RTLD_LAZY | RTLD_LOCAL);
		if (h)
			return h;
	}
	return NULL;
}

static void *
lx_dlopen_noload_any (const char *const *names)
{
	for (int i = 0; names[i]; i++) {
		void *h = dlopen(names[i], RTLD_LAZY | RTLD_NOLOAD);
		if (h)
			return h;
	}
	return NULL;
}

static void
lx_ensure_libs (void)
{
	if (g_lx.loaded)
		return;
	g_lx.loaded = 1;

	static const char *const x11_names[]     = { "libX11.so.6", "libX11.so", NULL };
	static const char *const xext_names[]    = { "libXext.so.6", "libXext.so", NULL };
	static const char *const egl_names[]     = { "libEGL.so.1", "libEGL.so", NULL };
	static const char *const glx_names[]     = { "libGLX.so.0", "libGL.so.1", "libGL.so", NULL };
	static const char *const gl_names[]      = { "libGL.so.1", "libOpenGL.so.0", "libGLESv2.so.2", "libGL.so", NULL };
	static const char *const wl_names[]      = { "libwayland-client.so.0", "libwayland-client.so", NULL };
	static const char *const wlegl_names[]   = { "libwayland-egl.so.1", "libwayland-egl.so", NULL };
	static const char *const gtk_names[]     = { "libgtk-3.so.0", "libgtk-3.so", NULL };
	static const char *const gdk_names[]     = { "libgdk-3.so.0", "libgdk-3.so", NULL };
	static const char *const glib_names[]    = { "libglib-2.0.so.0", "libglib-2.0.so", NULL };
	static const char *const gobject_names[] = { "libgobject-2.0.so.0", "libgobject-2.0.so", NULL };

	g_lx.x11 = lx_dlopen_any(x11_names);
	g_lx.xext = lx_dlopen_any(xext_names);
	g_lx.egl = lx_dlopen_any(egl_names);
	g_lx.glx = lx_dlopen_any(glx_names);
	g_lx.gl = lx_dlopen_any(gl_names);
	g_lx.wl_client = lx_dlopen_any(wl_names);
	g_lx.wl_egl = lx_dlopen_any(wlegl_names);
	g_lx.gtk = lx_dlopen_noload_any(gtk_names);
	g_lx.gdk = lx_dlopen_noload_any(gdk_names);
	g_lx.glib = lx_dlopen_noload_any(glib_names);
	g_lx.gobject = lx_dlopen_noload_any(gobject_names);

#define LX_SYM(lib, field, name) \
	do { if (lib) *(void **) (&g_lx.field) = dlsym((lib), (name)); } while (0)
#define LX_PROC_SYM(lib, field, name) \
	do { \
		void *_p = (lib) ? dlsym((lib), (name)) : NULL; \
		if (!_p) \
			_p = dlsym(RTLD_DEFAULT, (name)); \
		*(void **) (&g_lx.field) = _p; \
	} while (0)

	LX_SYM(g_lx.x11, XOpenDisplay, "XOpenDisplay");
	LX_SYM(g_lx.x11, XCloseDisplay, "XCloseDisplay");
	LX_SYM(g_lx.x11, XDefaultScreen, "XDefaultScreen");
	LX_SYM(g_lx.x11, XRootWindow, "XRootWindow");
	LX_SYM(g_lx.x11, XGetVisualInfo, "XGetVisualInfo");
	LX_SYM(g_lx.x11, XCreateColormap, "XCreateColormap");
	LX_SYM(g_lx.x11, XFreeColormap, "XFreeColormap");
	LX_SYM(g_lx.x11, XCreateWindow, "XCreateWindow");
	LX_SYM(g_lx.x11, XDestroyWindow, "XDestroyWindow");
	LX_SYM(g_lx.x11, XMoveResizeWindow, "XMoveResizeWindow");
	LX_SYM(g_lx.x11, XMapWindow, "XMapWindow");
	LX_SYM(g_lx.x11, XUnmapWindow, "XUnmapWindow");
	LX_SYM(g_lx.x11, XRaiseWindow, "XRaiseWindow");
	LX_SYM(g_lx.x11, XFlush, "XFlush");
	LX_SYM(g_lx.x11, XSync, "XSync");
	LX_SYM(g_lx.x11, XFree, "XFree");
	LX_SYM(g_lx.x11, XGetGeometry, "XGetGeometry");
	LX_SYM(g_lx.x11, XReparentWindow, "XReparentWindow");

	LX_SYM(g_lx.xext, XShapeCombineRectangles, "XShapeCombineRectangles");

	LX_SYM(g_lx.egl, eglGetDisplay, "eglGetDisplay");
	LX_SYM(g_lx.egl, eglGetPlatformDisplay, "eglGetPlatformDisplay");
	LX_SYM(g_lx.egl, eglInitialize, "eglInitialize");
	LX_SYM(g_lx.egl, eglTerminate, "eglTerminate");
	LX_SYM(g_lx.egl, eglBindAPI, "eglBindAPI");
	LX_SYM(g_lx.egl, eglChooseConfig, "eglChooseConfig");
	LX_SYM(g_lx.egl, eglGetConfigAttrib, "eglGetConfigAttrib");
	LX_SYM(g_lx.egl, eglCreateWindowSurface, "eglCreateWindowSurface");
	LX_SYM(g_lx.egl, eglDestroySurface, "eglDestroySurface");
	LX_SYM(g_lx.egl, eglCreateContext, "eglCreateContext");
	LX_SYM(g_lx.egl, eglDestroyContext, "eglDestroyContext");
	LX_SYM(g_lx.egl, eglMakeCurrent, "eglMakeCurrent");
	LX_SYM(g_lx.egl, eglSwapBuffers, "eglSwapBuffers");
	LX_SYM(g_lx.egl, eglSwapInterval, "eglSwapInterval");
	LX_SYM(g_lx.egl, eglGetProcAddress, "eglGetProcAddress");

	LX_SYM(g_lx.glx, glXChooseFBConfig, "glXChooseFBConfig");
	LX_SYM(g_lx.glx, glXGetVisualFromFBConfig, "glXGetVisualFromFBConfig");
	LX_SYM(g_lx.glx, glXCreateNewContext, "glXCreateNewContext");
	LX_SYM(g_lx.glx, glXMakeCurrent, "glXMakeCurrent");
	LX_SYM(g_lx.glx, glXDestroyContext, "glXDestroyContext");
	LX_SYM(g_lx.glx, glXSwapBuffers, "glXSwapBuffers");
	LX_SYM(g_lx.glx, glXGetProcAddressARB, "glXGetProcAddressARB");

	/* GTK3 / GDK3 / GLib: ONLY probe already-loaded in-process libraries.
	   Note: RTLD_DEFAULT is NULL on glibc, so never guard it with `if (lib)'.  */
	LX_PROC_SYM(g_lx.gtk,     gtk_window_list_toplevels,       "gtk_window_list_toplevels");
	LX_PROC_SYM(g_lx.gtk,     gtk_window_get_title,            "gtk_window_get_title");
	LX_PROC_SYM(g_lx.gtk,     gtk_widget_get_visible,          "gtk_widget_get_visible");
	LX_PROC_SYM(g_lx.gtk,     gtk_widget_get_allocated_width,  "gtk_widget_get_allocated_width");
	LX_PROC_SYM(g_lx.gtk,     gtk_widget_get_allocated_height, "gtk_widget_get_allocated_height");
	LX_PROC_SYM(g_lx.gtk,     gtk_widget_get_window,           "gtk_widget_get_window");
	LX_PROC_SYM(g_lx.gtk,     gtk_widget_get_has_window,       "gtk_widget_get_has_window");
	LX_PROC_SYM(g_lx.gtk,     gtk_widget_translate_coordinates,"gtk_widget_translate_coordinates");
	LX_PROC_SYM(g_lx.gtk,     gtk_container_get_children,      "gtk_container_get_children");
	LX_PROC_SYM(g_lx.gtk,     gtk_container_get_type,          "gtk_container_get_type");
	LX_PROC_SYM(g_lx.gtk,     gtk_window_is_active,            "gtk_window_is_active");
	LX_PROC_SYM(g_lx.gtk,     gtk_window_get_transient_for,    "gtk_window_get_transient_for");
	LX_PROC_SYM(g_lx.gdk,     gdk_window_get_display,          "gdk_window_get_display");
	LX_PROC_SYM(g_lx.gdk,     gdk_window_get_scale_factor,     "gdk_window_get_scale_factor");
	LX_PROC_SYM(g_lx.glib,    g_list_free,                     "g_list_free");
	LX_PROC_SYM(g_lx.gobject, g_type_name,                     "g_type_name");
	LX_PROC_SYM(g_lx.gobject, g_type_check_instance_is_a,      "g_type_check_instance_is_a");
	LX_PROC_SYM(g_lx.gdk,     gdk_x11_window_get_xid,          "gdk_x11_window_get_xid");
	LX_PROC_SYM(g_lx.gdk,     gdk_wayland_display_get_wl_display, "gdk_wayland_display_get_wl_display");
	LX_PROC_SYM(g_lx.gdk,     gdk_wayland_window_get_wl_surface,  "gdk_wayland_window_get_wl_surface");

	LX_SYM(g_lx.wl_client, wl_display_roundtrip, "wl_display_roundtrip");
	LX_SYM(g_lx.wl_client, wl_display_flush, "wl_display_flush");
	LX_SYM(g_lx.wl_client, wl_proxy_add_listener, "wl_proxy_add_listener");
	LX_SYM(g_lx.wl_client, wl_proxy_destroy, "wl_proxy_destroy");
	LX_SYM(g_lx.wl_client, wl_proxy_marshal, "wl_proxy_marshal");
	LX_SYM(g_lx.wl_client, wl_proxy_marshal_constructor, "wl_proxy_marshal_constructor");
	LX_SYM(g_lx.wl_client, wl_proxy_marshal_constructor_versioned, "wl_proxy_marshal_constructor_versioned");
	LX_SYM(g_lx.wl_client, wl_registry_iface, "wl_registry_interface");
	LX_SYM(g_lx.wl_client, wl_compositor_iface, "wl_compositor_interface");
	LX_SYM(g_lx.wl_client, wl_subcompositor_iface, "wl_subcompositor_interface");
	LX_SYM(g_lx.wl_client, wl_surface_iface, "wl_surface_interface");
	LX_SYM(g_lx.wl_client, wl_subsurface_iface, "wl_subsurface_interface");
	LX_SYM(g_lx.wl_client, wl_region_iface, "wl_region_interface");

	LX_SYM(g_lx.wl_egl, wl_egl_window_create, "wl_egl_window_create");
	LX_SYM(g_lx.wl_egl, wl_egl_window_resize, "wl_egl_window_resize");
	LX_SYM(g_lx.wl_egl, wl_egl_window_destroy, "wl_egl_window_destroy");
#undef LX_PROC_SYM
#undef LX_SYM
}

static bool
lx_has_x11_gl (void)
{
	bool x11_ok = g_lx.XOpenDisplay && g_lx.XCloseDisplay && g_lx.XCreateWindow
		&& g_lx.XDestroyWindow && g_lx.XMoveResizeWindow
		&& g_lx.XMapWindow && g_lx.XUnmapWindow && g_lx.XFlush;
	bool egl_ok = g_lx.eglGetDisplay && g_lx.eglInitialize && g_lx.eglChooseConfig
		&& g_lx.eglCreateWindowSurface && g_lx.eglCreateContext
		&& g_lx.eglMakeCurrent && g_lx.eglSwapBuffers && g_lx.eglGetProcAddress;
	bool glx_ok = g_lx.glXChooseFBConfig && g_lx.glXGetVisualFromFBConfig
		&& g_lx.glXCreateNewContext && g_lx.glXMakeCurrent
		&& g_lx.glXDestroyContext && g_lx.glXSwapBuffers && g_lx.glXGetProcAddressARB;
	return x11_ok && (egl_ok || glx_ok);
}

static bool
lx_has_wayland_gl (void)
{
	return g_lx.gtk_window_list_toplevels && g_lx.gtk_widget_get_window
		&& g_lx.gdk_window_get_display && g_lx.g_type_name
		&& g_lx.gdk_wayland_display_get_wl_display
		&& g_lx.gdk_wayland_window_get_wl_surface
		&& g_lx.wl_display_roundtrip && g_lx.wl_display_flush
		&& g_lx.wl_proxy_add_listener && g_lx.wl_proxy_destroy
		&& g_lx.wl_proxy_marshal && g_lx.wl_proxy_marshal_constructor
		&& g_lx.wl_proxy_marshal_constructor_versioned
		&& g_lx.wl_registry_iface && g_lx.wl_compositor_iface
		&& g_lx.wl_subcompositor_iface && g_lx.wl_surface_iface
		&& g_lx.wl_subsurface_iface && g_lx.wl_region_iface
		&& g_lx.wl_egl_window_create && g_lx.wl_egl_window_resize
		&& g_lx.wl_egl_window_destroy
		&& g_lx.eglInitialize && g_lx.eglChooseConfig
		&& g_lx.eglCreateWindowSurface && g_lx.eglCreateContext
		&& g_lx.eglMakeCurrent && g_lx.eglSwapBuffers && g_lx.eglGetProcAddress;
}

static const char *
lx_gtype_name (void *instance)
{
	if (!instance || !g_lx.g_type_name)
		return NULL;
	uintptr_t *klass = *(uintptr_t **) instance;
	if (!klass)
		return NULL;
	return g_lx.g_type_name(klass[0]);
}

static void *
lx_find_gtk_window (const char *title_hint, double content_w, double content_h, bool is_child)
{
	if (!g_lx.gtk_window_list_toplevels || !g_lx.g_list_free)
		return NULL;
	GList *list = g_lx.gtk_window_list_toplevels();
	if (!list)
		return NULL;

	void *best = NULL;
	double best_score = 1e18;
	for (GList *it = list; it; it = it->next) {
		void *w = it->data;
		if (!w)
			continue;
		if (g_lx.gtk_widget_get_visible && !g_lx.gtk_widget_get_visible(w))
			continue;
		void *gdk_win = g_lx.gtk_widget_get_window ? g_lx.gtk_widget_get_window(w) : NULL;
		if (!gdk_win)
			continue;
		int aw = g_lx.gtk_widget_get_allocated_width ? g_lx.gtk_widget_get_allocated_width(w) : 0;
		int ah = g_lx.gtk_widget_get_allocated_height ? g_lx.gtk_widget_get_allocated_height(w) : 0;
		if (aw < 16 || ah < 16)
			continue;

		bool w_child = g_lx.gtk_window_get_transient_for
			&& (g_lx.gtk_window_get_transient_for(w) != NULL);
		double score = (content_w > 0.0 && content_h > 0.0)
			? (fabs((double) aw - content_w) * 2.0 + fabs((double) ah - content_h) * 2.0)
			: 0.0;
		if (w_child != is_child)
			score += 500.0;
		if (title_hint && title_hint[0] && g_lx.gtk_window_get_title) {
			const char *t = g_lx.gtk_window_get_title(w);
			if (t && strcmp(t, title_hint) == 0)
				score -= 1000.0;
		}
		if (g_lx.gtk_window_is_active && g_lx.gtk_window_is_active(w))
			score -= 5.0;
		if (score < best_score) {
			best_score = score;
			best = w;
		}
	}
	g_lx.g_list_free(list);
	return best;
}

static bool
lx_widget_is_container (void *widget)
{
	if (!widget || !g_lx.gtk_container_get_type || !g_lx.g_type_check_instance_is_a)
		return false;
	return g_lx.g_type_check_instance_is_a(widget, g_lx.gtk_container_get_type()) != 0;
}

static bool
lx_widget_contains (void *root, void *needle, int depth)
{
	if (!root || !needle || depth > 16)
		return false;
	if (root == needle)
		return true;
	if (!lx_widget_is_container(root) || !g_lx.gtk_container_get_children || !g_lx.g_list_free)
		return false;
	GList *children = g_lx.gtk_container_get_children(root);
	bool found = false;
	for (GList *it = children; it && !found; it = it->next)
		found = lx_widget_contains(it->data, needle, depth + 1);
	g_lx.g_list_free(children);
	return found;
}

static void
lx_find_edit_widget_rec (void *widget, void *toplevel,
                         double cw, double ch, int depth,
                         void **best, double *best_score)
{
	if (!widget || depth > 16)
		return;
	if (widget != toplevel
	    && (!g_lx.gtk_widget_get_visible || g_lx.gtk_widget_get_visible(widget))) {
		int aw = g_lx.gtk_widget_get_allocated_width ? g_lx.gtk_widget_get_allocated_width(widget) : 0;
		int ah = g_lx.gtk_widget_get_allocated_height ? g_lx.gtk_widget_get_allocated_height(widget) : 0;
		const char *tn = lx_gtype_name(widget);
		if (aw >= 16 && ah >= 16 && tn) {
			bool is_canvas = (strstr(tn, "Fixed") != NULL)
				|| (strstr(tn, "DrawingArea") != NULL);
			if (is_canvas) {
				double score = (cw > 0.0 && ch > 0.0)
					? (fabs((double) aw - cw) + fabs((double) ah - ch))
					: 0.0;
				if (score < *best_score) {
					*best_score = score;
					*best = widget;
				}
			}
		}
	}
	if (!lx_widget_is_container(widget) || !g_lx.gtk_container_get_children || !g_lx.g_list_free)
		return;
	GList *children = g_lx.gtk_container_get_children(widget);
	for (GList *it = children; it; it = it->next)
		lx_find_edit_widget_rec(it->data, toplevel, cw, ch, depth + 1, best, best_score);
	g_lx.g_list_free(children);
}

static void *
lx_resolve_gtk_frame (uint64_t window_id,
                      const char *title_hint,
                      double content_w, double content_h,
                      bool is_child,
                      void **out_edit,
                      int *out_ox, int *out_oy)
{
	void *top = NULL;
	void *edit = NULL;
	if (out_edit)
		*out_edit = NULL;
	if (out_ox)
		*out_ox = 0;
	if (out_oy)
		*out_oy = 0;

	/* Safely validate a 64-bit GtkWidget* passed by PGTK Emacs via `window-id'.  */
	if (window_id > 0xFFFFFFFFULL && g_lx.gtk_window_list_toplevels && g_lx.g_list_free) {
		void *cand = (void *) (uintptr_t) window_id;
		GList *list = g_lx.gtk_window_list_toplevels();
		for (GList *it = list; it && !top; it = it->next) {
			void *w = it->data;
			if (!w)
				continue;
			if (w == cand) {
				top = w;
			} else if (lx_widget_contains(w, cand, 0)) {
				top = w;
				edit = cand;
			}
		}
		g_lx.g_list_free(list);
	}
	if (!top)
		top = lx_find_gtk_window(title_hint, content_w, content_h, is_child);
	if (!top)
		return NULL;
	if (!edit) {
		double best_score = 1e18;
		lx_find_edit_widget_rec(top, top, content_w, content_h, 0, &edit, &best_score);
	}
	if (out_edit)
		*out_edit = edit;
	if (edit && g_lx.gtk_widget_translate_coordinates) {
		int ox = 0, oy = 0;
		if (g_lx.gtk_widget_translate_coordinates(edit, top, 0, 0, &ox, &oy)) {
			if (out_ox)
				*out_ox = ox;
			if (out_oy)
				*out_oy = oy;
		}
	}
	return top;
}

static bool
lx_detect_wayland_session (void)
{
	if (!lx_has_wayland_gl())
		return false;
	void *gw = lx_find_gtk_window(NULL, 0, 0, false);
	if (!gw)
		return false;
	void *gdk_win = g_lx.gtk_widget_get_window(gw);
	const char *tname = lx_gtype_name(gdk_win);
	return tname && strstr(tname, "Wayland") != NULL;
}

/* -------------------------------------------------------------------------
   Shared OpenGL function loader & FBO snapshot helper
   ------------------------------------------------------------------------- */

typedef struct {
	void (*glClearColor)(GLfloat, GLfloat, GLfloat, GLfloat);
	void (*glClear)(GLbitfield);
	void (*glGenTextures)(GLsizei, GLuint *);
	void (*glBindTexture)(GLenum, GLuint);
	void (*glTexParameteri)(GLenum, GLenum, GLint);
	void (*glTexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
	void (*glDeleteTextures)(GLsizei, const GLuint *);
	void (*glPixelStorei)(GLenum, GLint);
	void (*glReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
	void (*glGenFramebuffers)(GLsizei, GLuint *);
	void (*glBindFramebuffer)(GLenum, GLuint);
	void (*glFramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
	GLenum (*glCheckFramebufferStatus)(GLenum);
	void (*glDeleteFramebuffers)(GLsizei, const GLuint *);
} etaf_gl_procs;

typedef enum {
	ETAF_LX_BACKEND_X11_EGL = 1,
	ETAF_LX_BACKEND_X11_GLX = 2,
	ETAF_LX_BACKEND_WAYLAND = 3
} etaf_lx_backend;

struct etaf_mpv_gpu {
	const etaf_mpv_api *api;
	mpv_handle *mpv;
	mpv_render_context *mpv_gl;
	etaf_lx_backend backend;
	etaf_gl_procs gl;

	/* X11 state (owned by render thread) */
	Display *xdpy;
	Window x_parent;
	Window x_win;
	Colormap x_cmap;
	bool x_mapped;

	/* EGL state */
	EGLDisplay egl_dpy;
	EGLConfig egl_cfg;
	EGLContext egl_ctx;
	EGLSurface egl_surf;

	/* GLX state */
	GLXFBConfig glx_cfg;
	GLXContext glx_ctx;

	/* Wayland state */
	struct wl_display *wl_dpy;
	struct wl_proxy *wl_compositor;
	struct wl_proxy *wl_subcompositor;
	uint32_t wl_comp_ver;
	struct wl_proxy *wl_parent_surf;
	struct wl_proxy *wl_surf;
	struct wl_proxy *wl_subsurf;
	struct wl_egl_window *wl_egl_win;
	int wl_scale;
	int wl_egl_w;
	int wl_egl_h;
	bool wl_attached;

	/* Threading & synchronization */
	pthread_t thread;
	pthread_mutex_t mu;
	pthread_cond_t cv;
	pthread_cond_t done_cv;
	bool thread_started;
	bool init_done;
	bool init_ok;

	atomic_int destroyed;
	atomic_int visible;
	atomic_int dirty;
	atomic_int force_redraw;
	atomic_uint_fast64_t frames;

	/* Pending geometry applied by render thread */
	bool geom_dirty;
	bool want_vis;
	Window want_x_parent;
	int want_x;
	int want_y;
	int want_w;
	int want_h;
	int want_scale;

	int last_x;
	int last_y;
	int last_w;
	int last_h;
	int last_scale;
	bool has_rect;

	/* Offscreen FBO snapshot request */
	bool grab_pending;
	bool grab_done;
	bool grab_ok;
	int grab_w;
	int grab_h;
	uint8_t *grab_dst;
};

static void *
lx_gl_get_proc (void *ctx, const char *name)
{
	etaf_mpv_gpu *gpu = (etaf_mpv_gpu *) ctx;
	if (!name)
		return NULL;
	void *p = NULL;
	if (gpu && gpu->backend == ETAF_LX_BACKEND_X11_GLX) {
		if (g_lx.glXGetProcAddressARB)
			p = g_lx.glXGetProcAddressARB((const unsigned char *) name);
	} else if (g_lx.eglGetProcAddress) {
		p = g_lx.eglGetProcAddress(name);
	}
	if (!p && g_lx.gl)
		p = dlsym(g_lx.gl, name);
	if (!p)
		p = dlsym(RTLD_DEFAULT, name);
	return p;
}

static void
lx_load_gl_procs (etaf_mpv_gpu *gpu)
{
#define GL_SYM(field, name) \
	*(void **) (&gpu->gl.field) = lx_gl_get_proc(gpu, (name))
	GL_SYM(glClearColor, "glClearColor");
	GL_SYM(glClear, "glClear");
	GL_SYM(glGenTextures, "glGenTextures");
	GL_SYM(glBindTexture, "glBindTexture");
	GL_SYM(glTexParameteri, "glTexParameteri");
	GL_SYM(glTexImage2D, "glTexImage2D");
	GL_SYM(glDeleteTextures, "glDeleteTextures");
	GL_SYM(glPixelStorei, "glPixelStorei");
	GL_SYM(glReadPixels, "glReadPixels");
	GL_SYM(glGenFramebuffers, "glGenFramebuffers");
	GL_SYM(glBindFramebuffer, "glBindFramebuffer");
	GL_SYM(glFramebufferTexture2D, "glFramebufferTexture2D");
	GL_SYM(glCheckFramebufferStatus, "glCheckFramebufferStatus");
	GL_SYM(glDeleteFramebuffers, "glDeleteFramebuffers");
#undef GL_SYM
}

static bool
lx_do_grab_rgba (etaf_mpv_gpu *gpu, int width, int height, uint8_t *dst_rgba)
{
	if (!gpu->mpv_gl || !dst_rgba || width <= 0 || height <= 0
	    || !gpu->gl.glGenTextures || !gpu->gl.glBindTexture
	    || !gpu->gl.glTexParameteri || !gpu->gl.glTexImage2D
	    || !gpu->gl.glDeleteTextures || !gpu->gl.glPixelStorei
	    || !gpu->gl.glReadPixels || !gpu->gl.glGenFramebuffers
	    || !gpu->gl.glBindFramebuffer || !gpu->gl.glFramebufferTexture2D
	    || !gpu->gl.glCheckFramebufferStatus || !gpu->gl.glDeleteFramebuffers)
		return false;

	GLuint tex = 0, fbo = 0;
	gpu->gl.glGenTextures(1, &tex);
	gpu->gl.glBindTexture(ETAF_GL_TEXTURE_2D, tex);
	gpu->gl.glTexParameteri(ETAF_GL_TEXTURE_2D, ETAF_GL_TEXTURE_MIN_FILTER, ETAF_GL_LINEAR);
	gpu->gl.glTexParameteri(ETAF_GL_TEXTURE_2D, ETAF_GL_TEXTURE_MAG_FILTER, ETAF_GL_LINEAR);
	gpu->gl.glTexImage2D(ETAF_GL_TEXTURE_2D, 0, ETAF_GL_RGBA8, width, height, 0,
	                     ETAF_GL_RGBA, ETAF_GL_UNSIGNED_BYTE, NULL);

	gpu->gl.glGenFramebuffers(1, &fbo);
	gpu->gl.glBindFramebuffer(ETAF_GL_FRAMEBUFFER, fbo);
	gpu->gl.glFramebufferTexture2D(ETAF_GL_FRAMEBUFFER, ETAF_GL_COLOR_ATTACHMENT0,
	                               ETAF_GL_TEXTURE_2D, tex, 0);

	bool ok = false;
	if (gpu->gl.glCheckFramebufferStatus(ETAF_GL_FRAMEBUFFER) == ETAF_GL_FRAMEBUFFER_COMPLETE) {
		etaf_mpv_opengl_fbo mfbo = {
			.fbo = (int) fbo,
			.w = width,
			.h = height,
			.internal_format = ETAF_GL_RGBA8
		};
		int flip = 0;
		int block = 0;
		etaf_mpv_render_param rparams[] = {
			{ ETAF_MPV_RP_OPENGL_FBO, &mfbo },
			{ ETAF_MPV_RP_FLIP_Y, &flip },
			{ ETAF_MPV_RP_BLOCK_FOR_TARGET_TIME, &block },
			{ ETAF_MPV_RP_INVALID, NULL }
		};
		if (gpu->api->render_context_render(gpu->mpv_gl, rparams) >= 0) {
			gpu->gl.glBindFramebuffer(ETAF_GL_FRAMEBUFFER, fbo);
			gpu->gl.glPixelStorei(ETAF_GL_PACK_ALIGNMENT, 1);
			gpu->gl.glReadPixels(0, 0, width, height, ETAF_GL_RGBA,
			                     ETAF_GL_UNSIGNED_BYTE, dst_rgba);
			ok = true;
		}
	}

	gpu->gl.glBindFramebuffer(ETAF_GL_FRAMEBUFFER, 0);
	gpu->gl.glBindTexture(ETAF_GL_TEXTURE_2D, 0);
	gpu->gl.glDeleteFramebuffers(1, &fbo);
	gpu->gl.glDeleteTextures(1, &tex);
	return ok;
}

static void
lx_on_update (void *cb_ctx)
{
	etaf_mpv_gpu *gpu = (etaf_mpv_gpu *) cb_ctx;
	if (!gpu || atomic_load_explicit(&gpu->destroyed, memory_order_acquire))
		return;
	atomic_store_explicit(&gpu->dirty, 1, memory_order_release);
	pthread_mutex_lock(&gpu->mu);
	pthread_cond_signal(&gpu->cv);
	pthread_mutex_unlock(&gpu->mu);
}

/* -------------------------------------------------------------------------
   Wayland registry & subsurface helpers
   ------------------------------------------------------------------------- */

typedef struct {
	struct wl_proxy *compositor;
	struct wl_proxy *subcompositor;
	uint32_t comp_ver;
} lx_wl_reg_ctx;

static void
lx_wl_reg_global (void *data, struct wl_proxy *reg, uint32_t name,
                  const char *interface, uint32_t version)
{
	lx_wl_reg_ctx *rc = (lx_wl_reg_ctx *) data;
	if (strcmp(interface, "wl_compositor") == 0 && !rc->compositor) {
		uint32_t v = version >= 4 ? 4 : version;
		rc->compositor = g_lx.wl_proxy_marshal_constructor_versioned(
			reg, 0, g_lx.wl_compositor_iface, v,
			name, g_lx.wl_compositor_iface->name, v, NULL);
		rc->comp_ver = v;
	} else if (strcmp(interface, "wl_subcompositor") == 0 && !rc->subcompositor) {
		rc->subcompositor = g_lx.wl_proxy_marshal_constructor_versioned(
			reg, 0, g_lx.wl_subcompositor_iface, 1,
			name, g_lx.wl_subcompositor_iface->name, 1, NULL);
	}
}

static void
lx_wl_reg_remove (void *data, struct wl_proxy *reg, uint32_t name)
{
	(void) data; (void) reg; (void) name;
}

static bool
lx_wl_init_globals (etaf_mpv_gpu *gpu, struct wl_display *dpy)
{
	struct wl_proxy *reg = g_lx.wl_proxy_marshal_constructor(
		(struct wl_proxy *) dpy, 1, g_lx.wl_registry_iface, NULL);
	if (!reg)
		return false;
	lx_wl_reg_ctx rc = { NULL, NULL, 1 };
	static const struct wl_registry_listener listener = {
		lx_wl_reg_global,
		lx_wl_reg_remove
	};
	g_lx.wl_proxy_add_listener(reg, (void (**)(void)) &listener, &rc);
	g_lx.wl_display_roundtrip(dpy);
	g_lx.wl_proxy_destroy(reg);
	if (!rc.compositor || !rc.subcompositor) {
		if (rc.compositor)
			g_lx.wl_proxy_destroy(rc.compositor);
		if (rc.subcompositor)
			g_lx.wl_proxy_destroy(rc.subcompositor);
		return false;
	}
	gpu->wl_dpy = dpy;
	gpu->wl_compositor = rc.compositor;
	gpu->wl_subcompositor = rc.subcompositor;
	gpu->wl_comp_ver = rc.comp_ver;
	return true;
}

static void
lx_wl_set_empty_input (etaf_mpv_gpu *gpu, struct wl_proxy *surf)
{
	struct wl_proxy *region = g_lx.wl_proxy_marshal_constructor(
		gpu->wl_compositor, 1, g_lx.wl_region_iface, NULL);
	if (!region)
		return;
	g_lx.wl_proxy_marshal(surf, 4, region); /* wl_surface.set_input_region */
	g_lx.wl_proxy_marshal(region, 0);       /* wl_region.destroy */
	g_lx.wl_proxy_destroy(region);
}

static bool
lx_egl_create_context_on_display (EGLDisplay edpy,
                                  EGLConfig *out_cfg, EGLContext *out_ctx)
{
	EGLint major = 0, minor = 0;
	if (!g_lx.eglInitialize(edpy, &major, &minor))
		return false;

	/* Prefer desktop OpenGL 3.2 Core; fall back to OpenGL ES 3.0 / 2.0.  */
	static const EGLint attrs_gl32[] = {
		ETAF_EGL_CONTEXT_MAJOR_VERSION, 3,
		ETAF_EGL_CONTEXT_MINOR_VERSION, 2,
		ETAF_EGL_CONTEXT_OPENGL_PROFILE_MASK, ETAF_EGL_CONTEXT_OPENGL_CORE_BIT,
		ETAF_EGL_NONE
	};
	static const EGLint attrs_gl_any[] = { ETAF_EGL_NONE };
	static const EGLint attrs_gles3[] = {
		ETAF_EGL_CONTEXT_MAJOR_VERSION, 3,
		ETAF_EGL_NONE
	};
	static const EGLint attrs_gles2[] = {
		ETAF_EGL_CONTEXT_MAJOR_VERSION, 2,
		ETAF_EGL_NONE
	};
	static const struct {
		EGLenum api;
		EGLint renderable;
		const EGLint *ctx_attrs;
	} attempts[] = {
		{ ETAF_EGL_OPENGL_API,    ETAF_EGL_OPENGL_BIT,     attrs_gl32   },
		{ ETAF_EGL_OPENGL_API,    ETAF_EGL_OPENGL_BIT,     attrs_gl_any },
		{ ETAF_EGL_OPENGL_ES_API, ETAF_EGL_OPENGL_ES2_BIT, attrs_gles3  },
		{ ETAF_EGL_OPENGL_ES_API, ETAF_EGL_OPENGL_ES2_BIT, attrs_gles2  },
	};

	for (size_t i = 0; i < sizeof attempts / sizeof attempts[0]; i++) {
		if (g_lx.eglBindAPI && !g_lx.eglBindAPI(attempts[i].api))
			continue;
		EGLint cfg_attrs[] = {
			ETAF_EGL_SURFACE_TYPE, ETAF_EGL_WINDOW_BIT,
			ETAF_EGL_RENDERABLE_TYPE, attempts[i].renderable,
			ETAF_EGL_RED_SIZE, 8,
			ETAF_EGL_GREEN_SIZE, 8,
			ETAF_EGL_BLUE_SIZE, 8,
			ETAF_EGL_ALPHA_SIZE, 0,
			ETAF_EGL_NONE
		};
		EGLConfig cfg = NULL;
		EGLint ncfg = 0;
		if (!g_lx.eglChooseConfig(edpy, cfg_attrs, &cfg, 1, &ncfg) || ncfg < 1)
			continue;
		EGLContext ctx = g_lx.eglCreateContext(edpy, cfg, ETAF_EGL_NO_CONTEXT,
		                                       attempts[i].ctx_attrs);
		if (ctx != ETAF_EGL_NO_CONTEXT) {
			*out_cfg = cfg;
			*out_ctx = ctx;
			return true;
		}
	}
	g_lx.eglTerminate(edpy);
	return false;
}

static bool
lx_init_x11_context (etaf_mpv_gpu *gpu)
{
	gpu->xdpy = g_lx.XOpenDisplay(NULL);
	if (!gpu->xdpy)
		return false;
	int screen = g_lx.XDefaultScreen(gpu->xdpy);
	Window root = g_lx.XRootWindow(gpu->xdpy, screen);
	Window parent = gpu->want_x_parent ? gpu->want_x_parent : root;
	gpu->x_parent = parent;

	/* Try EGL on X11 first.  */
	if (g_lx.eglInitialize && g_lx.eglChooseConfig && g_lx.eglCreateWindowSurface
	    && g_lx.eglCreateContext && g_lx.eglMakeCurrent && g_lx.eglSwapBuffers) {
		EGLDisplay edpy = ETAF_EGL_NO_DISPLAY;
		if (g_lx.eglGetPlatformDisplay)
			edpy = g_lx.eglGetPlatformDisplay(ETAF_EGL_PLATFORM_X11_KHR, gpu->xdpy, NULL);
		if (edpy == ETAF_EGL_NO_DISPLAY && g_lx.eglGetDisplay)
			edpy = g_lx.eglGetDisplay(gpu->xdpy);

		EGLConfig cfg = NULL;
		EGLContext ctx = ETAF_EGL_NO_CONTEXT;
		if (edpy != ETAF_EGL_NO_DISPLAY
		    && lx_egl_create_context_on_display(edpy, &cfg, &ctx)) {
			EGLint vid = 0;
			XVisualInfo *vi = NULL;
			if (g_lx.eglGetConfigAttrib && g_lx.XGetVisualInfo
			    && g_lx.eglGetConfigAttrib(edpy, cfg, ETAF_EGL_NATIVE_VISUAL_ID, &vid)
			    && vid != 0) {
				XVisualInfo tmpl;
				memset(&tmpl, 0, sizeof tmpl);
				tmpl.visualid = (unsigned long) vid;
				int nvi = 0;
				vi = g_lx.XGetVisualInfo(gpu->xdpy, ETAF_X11_VISUAL_ID_MASK, &tmpl, &nvi);
			}

			XSetWindowAttributes swa;
			memset(&swa, 0, sizeof swa);
			swa.background_pixmap = ETAF_X11_NONE;
			swa.border_pixel = 0;
			unsigned long mask = ETAF_X11_CW_BACK_PIXMAP | ETAF_X11_CW_BORDER_PIX;
			int depth = 0;
			XVisual *visual = NULL;
			if (vi) {
				depth = vi->depth;
				visual = vi->visual;
				if (g_lx.XCreateColormap) {
					gpu->x_cmap = g_lx.XCreateColormap(
						gpu->xdpy, root, visual, ETAF_X11_ALLOC_NONE);
					swa.colormap = gpu->x_cmap;
					mask |= ETAF_X11_CW_COLORMAP;
				}
			}
			Window xwin = g_lx.XCreateWindow(
				gpu->xdpy, parent, 0, 0, 1, 1, 0, depth,
				ETAF_X11_INPUT_OUTPUT, visual, mask, &swa);
			if (vi && g_lx.XFree)
				g_lx.XFree(vi);

			if (xwin) {
				if (g_lx.XShapeCombineRectangles)
					g_lx.XShapeCombineRectangles(
						gpu->xdpy, xwin, ETAF_X11_SHAPE_INPUT,
						0, 0, NULL, 0, ETAF_X11_SHAPE_SET, 0);
				EGLSurface surf = g_lx.eglCreateWindowSurface(
					edpy, cfg, (uintptr_t) xwin, NULL);
				if (surf != ETAF_EGL_NO_SURFACE
				    && g_lx.eglMakeCurrent(edpy, surf, surf, ctx)) {
					if (g_lx.eglSwapInterval)
						g_lx.eglSwapInterval(edpy, 0);
					gpu->backend = ETAF_LX_BACKEND_X11_EGL;
					gpu->x_win = xwin;
					gpu->egl_dpy = edpy;
					gpu->egl_cfg = cfg;
					gpu->egl_ctx = ctx;
					gpu->egl_surf = surf;
					g_lx.XFlush(gpu->xdpy);
					return true;
				}
				if (surf != ETAF_EGL_NO_SURFACE)
					g_lx.eglDestroySurface(edpy, surf);
				g_lx.XDestroyWindow(gpu->xdpy, xwin);
			}
			if (gpu->x_cmap && g_lx.XFreeColormap) {
				g_lx.XFreeColormap(gpu->xdpy, gpu->x_cmap);
				gpu->x_cmap = 0;
			}
			g_lx.eglDestroyContext(edpy, ctx);
			g_lx.eglTerminate(edpy);
		}
	}

	/* Fallback: GLX on X11.  */
	if (g_lx.glXChooseFBConfig && g_lx.glXGetVisualFromFBConfig
	    && g_lx.glXCreateNewContext && g_lx.glXMakeCurrent
	    && g_lx.glXDestroyContext && g_lx.glXSwapBuffers) {
		static const int fb_attrs[] = {
			ETAF_GLX_X_RENDERABLE, 1,
			ETAF_GLX_DRAWABLE_TYPE, ETAF_GLX_WINDOW_BIT,
			ETAF_GLX_RENDER_TYPE, ETAF_GLX_RGBA_BIT,
			ETAF_GLX_X_VISUAL_TYPE, ETAF_GLX_TRUE_COLOR,
			ETAF_GLX_RED_SIZE, 8,
			ETAF_GLX_GREEN_SIZE, 8,
			ETAF_GLX_BLUE_SIZE, 8,
			ETAF_GLX_DOUBLEBUFFER, 1,
			0
		};
		int nfb = 0;
		GLXFBConfig *fbs = g_lx.glXChooseFBConfig(gpu->xdpy, screen, fb_attrs, &nfb);
		if (fbs && nfb > 0) {
			GLXFBConfig fbc = fbs[0];
			XVisualInfo *vi = g_lx.glXGetVisualFromFBConfig(gpu->xdpy, fbc);
			if (g_lx.XFree)
				g_lx.XFree(fbs);
			if (vi) {
				XSetWindowAttributes swa;
				memset(&swa, 0, sizeof swa);
				swa.background_pixmap = ETAF_X11_NONE;
				swa.border_pixel = 0;
				unsigned long mask = ETAF_X11_CW_BACK_PIXMAP | ETAF_X11_CW_BORDER_PIX;
				if (g_lx.XCreateColormap) {
					gpu->x_cmap = g_lx.XCreateColormap(
						gpu->xdpy, root, vi->visual, ETAF_X11_ALLOC_NONE);
					swa.colormap = gpu->x_cmap;
					mask |= ETAF_X11_CW_COLORMAP;
				}
				Window xwin = g_lx.XCreateWindow(
					gpu->xdpy, parent, 0, 0, 1, 1, 0, vi->depth,
					ETAF_X11_INPUT_OUTPUT, vi->visual, mask, &swa);
				if (g_lx.XFree)
					g_lx.XFree(vi);
				if (xwin) {
					if (g_lx.XShapeCombineRectangles)
						g_lx.XShapeCombineRectangles(
							gpu->xdpy, xwin, ETAF_X11_SHAPE_INPUT,
							0, 0, NULL, 0, ETAF_X11_SHAPE_SET, 0);
					GLXContext gctx = NULL;
					typedef GLXContext (*pfn_glx_create_attribs)(
						Display *, GLXFBConfig, GLXContext, XBool, const int *);
					pfn_glx_create_attribs create_attribs = g_lx.glXGetProcAddressARB
						? (pfn_glx_create_attribs) g_lx.glXGetProcAddressARB(
							(const unsigned char *) "glXCreateContextAttribsARB")
						: NULL;
					if (create_attribs) {
						static const int cattrs[] = {
							ETAF_GLX_CONTEXT_MAJOR_ARB, 3,
							ETAF_GLX_CONTEXT_MINOR_ARB, 2,
							ETAF_GLX_CONTEXT_PROFILE_MASK_ARB, ETAF_GLX_CONTEXT_CORE_BIT_ARB,
							0
						};
						gctx = create_attribs(gpu->xdpy, fbc, NULL, 1, cattrs);
					}
					if (!gctx)
						gctx = g_lx.glXCreateNewContext(
							gpu->xdpy, fbc, ETAF_GLX_RGBA_BIT, NULL, 1);
					if (gctx && g_lx.glXMakeCurrent(gpu->xdpy, xwin, gctx)) {
						gpu->backend = ETAF_LX_BACKEND_X11_GLX;
						gpu->x_win = xwin;
						gpu->glx_cfg = fbc;
						gpu->glx_ctx = gctx;
						g_lx.XFlush(gpu->xdpy);
						return true;
					}
					if (gctx)
						g_lx.glXDestroyContext(gpu->xdpy, gctx);
					g_lx.XDestroyWindow(gpu->xdpy, xwin);
				}
			}
		}
	}

	g_lx.XCloseDisplay(gpu->xdpy);
	gpu->xdpy = NULL;
	return false;
}

static bool
lx_init_wayland_context (etaf_mpv_gpu *gpu)
{
	if (!gpu->wl_dpy || !gpu->wl_egl_win)
		return false;
	EGLDisplay edpy = ETAF_EGL_NO_DISPLAY;
	if (g_lx.eglGetPlatformDisplay)
		edpy = g_lx.eglGetPlatformDisplay(ETAF_EGL_PLATFORM_WAYLAND_KHR, gpu->wl_dpy, NULL);
	if (edpy == ETAF_EGL_NO_DISPLAY && g_lx.eglGetDisplay)
		edpy = g_lx.eglGetDisplay(gpu->wl_dpy);
	if (edpy == ETAF_EGL_NO_DISPLAY)
		return false;

	EGLConfig cfg = NULL;
	EGLContext ctx = ETAF_EGL_NO_CONTEXT;
	if (!lx_egl_create_context_on_display(edpy, &cfg, &ctx))
		return false;

	EGLSurface surf = g_lx.eglCreateWindowSurface(
		edpy, cfg, (uintptr_t) gpu->wl_egl_win, NULL);
	if (surf == ETAF_EGL_NO_SURFACE || !g_lx.eglMakeCurrent(edpy, surf, surf, ctx)) {
		if (surf != ETAF_EGL_NO_SURFACE)
			g_lx.eglDestroySurface(edpy, surf);
		g_lx.eglDestroyContext(edpy, ctx);
		g_lx.eglTerminate(edpy);
		return false;
	}
	if (g_lx.eglSwapInterval)
		g_lx.eglSwapInterval(edpy, 0);

	gpu->backend = ETAF_LX_BACKEND_WAYLAND;
	gpu->egl_dpy = edpy;
	gpu->egl_cfg = cfg;
	gpu->egl_ctx = ctx;
	gpu->egl_surf = surf;
	return true;
}

static void *
lx_render_thread (void *arg)
{
	etaf_mpv_gpu *gpu = (etaf_mpv_gpu *) arg;
	bool ok = (gpu->backend == ETAF_LX_BACKEND_WAYLAND)
		? lx_init_wayland_context(gpu)
		: lx_init_x11_context(gpu);

	if (ok) {
		lx_load_gl_procs(gpu);
		etaf_mpv_opengl_init_params gl_init = {
			.get_proc_address = lx_gl_get_proc,
			.get_proc_address_ctx = gpu
		};
		etaf_mpv_render_param params[] = {
			{ ETAF_MPV_RP_API_TYPE, (void *) "opengl" },
			{ ETAF_MPV_RP_OPENGL_INIT_PARAMS, &gl_init },
			{ ETAF_MPV_RP_INVALID, NULL }
		};
		if (gpu->api->render_context_create(&gpu->mpv_gl, gpu->mpv, params) < 0
		    || !gpu->mpv_gl) {
			ok = false;
		} else {
			gpu->api->render_context_set_update_callback(
				gpu->mpv_gl, lx_on_update, gpu);
		}
	}

	pthread_mutex_lock(&gpu->mu);
	gpu->init_ok = ok;
	gpu->init_done = true;
	pthread_cond_broadcast(&gpu->done_cv);
	pthread_mutex_unlock(&gpu->mu);

	if (!ok)
		goto cleanup;

	for (;;) {
		pthread_mutex_lock(&gpu->mu);
		while (!atomic_load_explicit(&gpu->destroyed, memory_order_acquire)
		       && !atomic_load_explicit(&gpu->dirty, memory_order_acquire)
		       && !atomic_load_explicit(&gpu->force_redraw, memory_order_acquire)
		       && !gpu->geom_dirty
		       && !gpu->grab_pending) {
			struct timespec ts;
			clock_gettime(CLOCK_REALTIME, &ts);
			ts.tv_nsec += 100000000L;
			if (ts.tv_nsec >= 1000000000L) {
				ts.tv_sec += 1;
				ts.tv_nsec -= 1000000000L;
			}
			pthread_cond_timedwait(&gpu->cv, &gpu->mu, &ts);
		}
		if (atomic_load_explicit(&gpu->destroyed, memory_order_acquire)) {
			pthread_mutex_unlock(&gpu->mu);
			break;
		}

		bool geom = gpu->geom_dirty;
		bool vis = gpu->want_vis;
		Window want_parent = gpu->want_x_parent;
		int gx = gpu->want_x, gy = gpu->want_y;
		int gw = gpu->want_w, gh = gpu->want_h;
		int gscale = gpu->want_scale > 0 ? gpu->want_scale : 1;
		gpu->geom_dirty = false;

		bool do_grab = gpu->grab_pending;
		int snap_w = gpu->grab_w, snap_h = gpu->grab_h;
		uint8_t *snap_dst = gpu->grab_dst;
		gpu->grab_pending = false;
		pthread_mutex_unlock(&gpu->mu);

		if (do_grab) {
			bool gok = lx_do_grab_rgba(gpu, snap_w, snap_h, snap_dst);
			pthread_mutex_lock(&gpu->mu);
			gpu->grab_ok = gok;
			gpu->grab_done = true;
			pthread_cond_broadcast(&gpu->done_cv);
			pthread_mutex_unlock(&gpu->mu);
		}

		if (geom) {
			if (gpu->backend == ETAF_LX_BACKEND_X11_EGL
			    || gpu->backend == ETAF_LX_BACKEND_X11_GLX) {
				if (!vis || gw < 1 || gh < 1) {
					if (gpu->x_mapped) {
						g_lx.XUnmapWindow(gpu->xdpy, gpu->x_win);
						g_lx.XFlush(gpu->xdpy);
						gpu->x_mapped = false;
					}
				} else {
					if (want_parent && want_parent != gpu->x_parent
					    && g_lx.XReparentWindow) {
						g_lx.XReparentWindow(gpu->xdpy, gpu->x_win,
						                     want_parent, gx, gy);
						gpu->x_parent = want_parent;
					}
					g_lx.XMoveResizeWindow(gpu->xdpy, gpu->x_win,
					                       gx, gy,
					                       (unsigned int) gw,
					                       (unsigned int) gh);
					if (!gpu->x_mapped) {
						g_lx.XMapWindow(gpu->xdpy, gpu->x_win);
						gpu->x_mapped = true;
					}
					if (g_lx.XRaiseWindow)
						g_lx.XRaiseWindow(gpu->xdpy, gpu->x_win);
					g_lx.XFlush(gpu->xdpy);
				}
			} else if (gpu->backend == ETAF_LX_BACKEND_WAYLAND) {
				if (!vis || gw < 1 || gh < 1) {
					if (gpu->wl_attached && gpu->wl_surf) {
						g_lx.wl_proxy_marshal(gpu->wl_surf, 1, NULL, 0, 0); /* attach NULL */
						g_lx.wl_proxy_marshal(gpu->wl_surf, 6);            /* commit */
						g_lx.wl_display_flush(gpu->wl_dpy);
						gpu->wl_attached = false;
					}
				} else {
					int pw = gw * gscale;
					int ph = gh * gscale;
					if (pw != gpu->wl_egl_w || ph != gpu->wl_egl_h) {
						g_lx.wl_egl_window_resize(gpu->wl_egl_win, pw, ph, 0, 0);
						gpu->wl_egl_w = pw;
						gpu->wl_egl_h = ph;
					}
				}
			}
		}

		int was_dirty = atomic_exchange_explicit(&gpu->dirty, 0, memory_order_acq_rel);
		int force = atomic_exchange_explicit(&gpu->force_redraw, 0, memory_order_acq_rel);
		if (!was_dirty && !force)
			continue;

		uint64_t flags = gpu->api->render_context_update(gpu->mpv_gl);
		bool active_vis = atomic_load_explicit(&gpu->visible, memory_order_acquire) != 0;
		if (active_vis && gw > 0 && gh > 0) {
			if ((flags & ETAF_MPV_RENDER_UPDATE_FRAME) || force) {
				int pw = (gpu->backend == ETAF_LX_BACKEND_WAYLAND)
					? (gw * gscale) : gw;
				int ph = (gpu->backend == ETAF_LX_BACKEND_WAYLAND)
					? (gh * gscale) : gh;
				etaf_mpv_opengl_fbo mfbo = {
					.fbo = 0,
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
				if (gpu->api->render_context_render(gpu->mpv_gl, rparams) >= 0) {
					if (gpu->backend == ETAF_LX_BACKEND_X11_GLX)
						g_lx.glXSwapBuffers(gpu->xdpy, gpu->x_win);
					else
						g_lx.eglSwapBuffers(gpu->egl_dpy, gpu->egl_surf);
					if (gpu->backend == ETAF_LX_BACKEND_WAYLAND)
						gpu->wl_attached = true;
					gpu->api->render_context_report_swap(gpu->mpv_gl);
					atomic_fetch_add_explicit(&gpu->frames, 1, memory_order_relaxed);
				}
			}
		} else if (flags & ETAF_MPV_RENDER_UPDATE_FRAME) {
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

cleanup:
	if (gpu->mpv_gl) {
		gpu->api->render_context_set_update_callback(gpu->mpv_gl, NULL, NULL);
		gpu->api->render_context_free(gpu->mpv_gl);
		gpu->mpv_gl = NULL;
	}
	if (gpu->backend == ETAF_LX_BACKEND_X11_GLX) {
		if (gpu->xdpy && gpu->glx_ctx) {
			g_lx.glXMakeCurrent(gpu->xdpy, 0, NULL);
			g_lx.glXDestroyContext(gpu->xdpy, gpu->glx_ctx);
			gpu->glx_ctx = NULL;
		}
	} else if (gpu->egl_dpy != ETAF_EGL_NO_DISPLAY) {
		g_lx.eglMakeCurrent(gpu->egl_dpy, ETAF_EGL_NO_SURFACE,
		                    ETAF_EGL_NO_SURFACE, ETAF_EGL_NO_CONTEXT);
		if (gpu->egl_surf != ETAF_EGL_NO_SURFACE)
			g_lx.eglDestroySurface(gpu->egl_dpy, gpu->egl_surf);
		if (gpu->egl_ctx != ETAF_EGL_NO_CONTEXT)
			g_lx.eglDestroyContext(gpu->egl_dpy, gpu->egl_ctx);
		g_lx.eglTerminate(gpu->egl_dpy);
		gpu->egl_surf = ETAF_EGL_NO_SURFACE;
		gpu->egl_ctx = ETAF_EGL_NO_CONTEXT;
		gpu->egl_dpy = ETAF_EGL_NO_DISPLAY;
	}
	if (gpu->xdpy) {
		if (gpu->x_win) {
			g_lx.XDestroyWindow(gpu->xdpy, gpu->x_win);
			gpu->x_win = 0;
		}
		if (gpu->x_cmap && g_lx.XFreeColormap) {
			g_lx.XFreeColormap(gpu->xdpy, gpu->x_cmap);
			gpu->x_cmap = 0;
		}
		g_lx.XCloseDisplay(gpu->xdpy);
		gpu->xdpy = NULL;
	}
	return NULL;
}

/* -------------------------------------------------------------------------
   Public platform GPU hooks
   ------------------------------------------------------------------------- */

bool
etaf_mpv_gpu_platform_available (void)
{
	lx_ensure_libs();
	if (lx_detect_wayland_session())
		return true;
	const char *dpy = getenv("DISPLAY");
	if (dpy && dpy[0] && lx_has_x11_gl()) {
		Display *test = g_lx.XOpenDisplay(NULL);
		if (test) {
			g_lx.XCloseDisplay(test);
			return true;
		}
	}
	return false;
}

etaf_mpv_gpu *
etaf_mpv_gpu_create (mpv_handle *mpv, const etaf_mpv_api *api)
{
	if (!mpv || !api)
		return NULL;
	lx_ensure_libs();

	bool use_wayland = lx_detect_wayland_session();
	if (!use_wayland) {
		const char *dpy = getenv("DISPLAY");
		if (!dpy || !dpy[0] || !lx_has_x11_gl())
			return NULL;
	}

	etaf_mpv_gpu *gpu = calloc(1, sizeof *gpu);
	if (!gpu)
		return NULL;
	gpu->api = api;
	gpu->mpv = mpv;
	gpu->want_scale = 1;
	gpu->wl_scale = 1;
	atomic_init(&gpu->destroyed, 0);
	atomic_init(&gpu->visible, 0);
	atomic_init(&gpu->dirty, 0);
	atomic_init(&gpu->force_redraw, 0);
	atomic_init(&gpu->frames, 0);
	pthread_mutex_init(&gpu->mu, NULL);
	pthread_cond_init(&gpu->cv, NULL);
	pthread_cond_init(&gpu->done_cv, NULL);

	if (use_wayland) {
		void *gw = lx_find_gtk_window(NULL, 0, 0, false);
		void *gdk_win = gw ? g_lx.gtk_widget_get_window(gw) : NULL;
		void *gdk_dpy = gdk_win ? g_lx.gdk_window_get_display(gdk_win) : NULL;
		struct wl_display *wld = gdk_dpy ? g_lx.gdk_wayland_display_get_wl_display(gdk_dpy) : NULL;
		struct wl_proxy *parent_surf = gdk_win ? g_lx.gdk_wayland_window_get_wl_surface(gdk_win) : NULL;
		if (!wld || !parent_surf || !lx_wl_init_globals(gpu, wld))
			goto fail;

		gpu->wl_surf = g_lx.wl_proxy_marshal_constructor(
			gpu->wl_compositor, 0, g_lx.wl_surface_iface, NULL);
		if (!gpu->wl_surf)
			goto fail;
		lx_wl_set_empty_input(gpu, gpu->wl_surf);
		gpu->wl_subsurf = g_lx.wl_proxy_marshal_constructor(
			gpu->wl_subcompositor, 1, g_lx.wl_subsurface_iface,
			NULL, gpu->wl_surf, parent_surf);
		if (!gpu->wl_subsurf)
			goto fail;
		gpu->wl_parent_surf = parent_surf;
		g_lx.wl_proxy_marshal(gpu->wl_subsurf, 5); /* set_desync */
		g_lx.wl_proxy_marshal(gpu->wl_surf, 6);    /* commit */
		g_lx.wl_display_flush(wld);

		gpu->wl_egl_w = 1;
		gpu->wl_egl_h = 1;
		gpu->wl_egl_win = g_lx.wl_egl_window_create(gpu->wl_surf, 1, 1);
		if (!gpu->wl_egl_win)
			goto fail;
		gpu->backend = ETAF_LX_BACKEND_WAYLAND;
	} else {
		gpu->backend = ETAF_LX_BACKEND_X11_EGL;
	}

	if (pthread_create(&gpu->thread, NULL, lx_render_thread, gpu) != 0)
		goto fail;
	gpu->thread_started = true;

	pthread_mutex_lock(&gpu->mu);
	while (!gpu->init_done)
		pthread_cond_wait(&gpu->done_cv, &gpu->mu);
	bool ok = gpu->init_ok;
	pthread_mutex_unlock(&gpu->mu);

	if (!ok)
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
	(void) outer_left; (void) outer_top;
	if (!gpu || atomic_load_explicit(&gpu->destroyed, memory_order_acquire))
		return false;

	bool want_vis = visible && w >= 1.0 && h >= 1.0;
	bool prev_vis = atomic_load_explicit(&gpu->visible, memory_order_acquire) != 0;

	if (!want_vis) {
		atomic_store_explicit(&gpu->visible, 0, memory_order_release);
		pthread_mutex_lock(&gpu->mu);
		gpu->want_vis = false;
		gpu->geom_dirty = true;
		pthread_cond_signal(&gpu->cv);
		pthread_mutex_unlock(&gpu->mu);
		return true;
	}

	if (gpu->backend == ETAF_LX_BACKEND_WAYLAND) {
		void *edit = NULL;
		int ox = 0, oy = 0;
		void *gw = lx_resolve_gtk_frame(window_id, title_hint, content_w, content_h,
		                                is_child, &edit, &ox, &oy);
		void *gdk_win = gw ? g_lx.gtk_widget_get_window(gw) : NULL;
		struct wl_proxy *parent_surf = gdk_win
			? g_lx.gdk_wayland_window_get_wl_surface(gdk_win) : NULL;
		if (!parent_surf) {
			atomic_store_explicit(&gpu->visible, 0, memory_order_release);
			return false;
		}
		int scale = (g_lx.gdk_window_get_scale_factor && gdk_win)
			? g_lx.gdk_window_get_scale_factor(gdk_win) : 1;
		if (scale < 1)
			scale = 1;
		int lx = (int) llround(x) + ox;
		int ly = (int) llround(y) + oy;
		int lw = (int) llround(w);
		int lh = (int) llround(h);

		bool parent_changed = (parent_surf != gpu->wl_parent_surf);
		bool geom_changed = !gpu->has_rect || gpu->last_x != lx || gpu->last_y != ly
			|| gpu->last_w != lw || gpu->last_h != lh || gpu->last_scale != scale;

		if (parent_changed && gpu->wl_subsurf) {
			g_lx.wl_proxy_marshal(gpu->wl_subsurf, 0); /* destroy */
			g_lx.wl_proxy_destroy(gpu->wl_subsurf);
			gpu->wl_subsurf = g_lx.wl_proxy_marshal_constructor(
				gpu->wl_subcompositor, 1, g_lx.wl_subsurface_iface,
				NULL, gpu->wl_surf, parent_surf);
			if (!gpu->wl_subsurf)
				return false;
			gpu->wl_parent_surf = parent_surf;
			g_lx.wl_proxy_marshal(gpu->wl_subsurf, 5); /* set_desync */
		}

		if (parent_changed || geom_changed || !prev_vis) {
			g_lx.wl_proxy_marshal(gpu->wl_subsurf, 1, lx, ly); /* set_position */
			if (gpu->wl_comp_ver >= 3)
				g_lx.wl_proxy_marshal(gpu->wl_surf, 8, scale); /* set_buffer_scale */
			g_lx.wl_proxy_marshal(gpu->wl_surf, 6);            /* commit */
			g_lx.wl_display_flush(gpu->wl_dpy);

			gpu->last_x = lx;
			gpu->last_y = ly;
			gpu->last_w = lw;
			gpu->last_h = lh;
			gpu->last_scale = scale;
			gpu->has_rect = true;

			atomic_store_explicit(&gpu->visible, 1, memory_order_release);
			pthread_mutex_lock(&gpu->mu);
			gpu->want_vis = true;
			gpu->want_x = lx;
			gpu->want_y = ly;
			gpu->want_w = lw;
			gpu->want_h = lh;
			gpu->want_scale = scale;
			gpu->geom_dirty = true;
			atomic_store_explicit(&gpu->force_redraw, 1, memory_order_release);
			pthread_cond_signal(&gpu->cv);
			pthread_mutex_unlock(&gpu->mu);
		}
		return true;
	}

	/* X11 backend: prefer Emacs `window-id' when it is a valid 32-bit XID.
	   On PGTK Emacs running under X11, `window-id' holds a 64-bit GtkWidget*
	   pointer rather than an X11 XID, so resolve the XID and edit-widget
	   offset (below GTK menu-bar / tool-bar) via in-process GDK3.  */
	Window target_xid = (window_id > 0 && window_id <= 0xFFFFFFFFULL)
		? (Window) window_id : 0;
	int scale = 1;
	int ox = 0, oy = 0;
	if (!target_xid && g_lx.gdk_x11_window_get_xid) {
		void *edit = NULL;
		void *gw = lx_resolve_gtk_frame(window_id, title_hint, content_w, content_h,
		                                is_child, &edit, &ox, &oy);
		void *top_gdk = gw ? g_lx.gtk_widget_get_window(gw) : NULL;
		const char *tname = lx_gtype_name(top_gdk);
		if (top_gdk && (!tname || strstr(tname, "X11") != NULL)) {
			Window top_xid = (Window) g_lx.gdk_x11_window_get_xid(top_gdk);
			target_xid = top_xid;
			if (edit && g_lx.gtk_widget_get_has_window && g_lx.gtk_widget_get_has_window(edit)) {
				void *edit_gdk = g_lx.gtk_widget_get_window(edit);
				if (edit_gdk && edit_gdk != top_gdk) {
					Window edit_xid = (Window) g_lx.gdk_x11_window_get_xid(edit_gdk);
					if (edit_xid && edit_xid != top_xid) {
						target_xid = edit_xid;
						ox = 0;
						oy = 0;
					}
				}
			}
			if (g_lx.gdk_window_get_scale_factor) {
				scale = g_lx.gdk_window_get_scale_factor(top_gdk);
				if (scale < 1)
					scale = 1;
			}
		}
	}
	if (!target_xid) {
		atomic_store_explicit(&gpu->visible, 0, memory_order_release);
		return false;
	}

	int px = (int) llround((x + (double) ox) * scale);
	int py = (int) llround((y + (double) oy) * scale);
	int pw = (int) llround(w * scale);
	int ph = (int) llround(h * scale);

	bool parent_changed = (target_xid != gpu->want_x_parent);
	bool geom_changed = !gpu->has_rect || gpu->last_x != px || gpu->last_y != py
		|| gpu->last_w != pw || gpu->last_h != ph;

	atomic_store_explicit(&gpu->visible, 1, memory_order_release);
	if (parent_changed || geom_changed || !prev_vis) {
		gpu->last_x = px;
		gpu->last_y = py;
		gpu->last_w = pw;
		gpu->last_h = ph;
		gpu->has_rect = true;

		pthread_mutex_lock(&gpu->mu);
		gpu->want_x_parent = target_xid;
		gpu->want_vis = true;
		gpu->want_x = px;
		gpu->want_y = py;
		gpu->want_w = pw;
		gpu->want_h = ph;
		gpu->geom_dirty = true;
		atomic_store_explicit(&gpu->force_redraw, 1, memory_order_release);
		pthread_cond_signal(&gpu->cv);
		pthread_mutex_unlock(&gpu->mu);
	}
	return true;
}

void
etaf_mpv_gpu_request_redraw (etaf_mpv_gpu *gpu)
{
	if (!gpu || atomic_load_explicit(&gpu->destroyed, memory_order_acquire))
		return;
	atomic_store_explicit(&gpu->force_redraw, 1, memory_order_release);
	pthread_mutex_lock(&gpu->mu);
	pthread_cond_signal(&gpu->cv);
	pthread_mutex_unlock(&gpu->mu);
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
	    || !gpu->thread_started)
		return false;

	pthread_mutex_lock(&gpu->mu);
	gpu->grab_w = width;
	gpu->grab_h = height;
	gpu->grab_dst = dst_rgba;
	gpu->grab_ok = false;
	gpu->grab_done = false;
	gpu->grab_pending = true;
	pthread_cond_signal(&gpu->cv);

	struct timespec until;
	clock_gettime(CLOCK_REALTIME, &until);
	until.tv_sec += 2;
	while (!gpu->grab_done
	       && !atomic_load_explicit(&gpu->destroyed, memory_order_acquire)) {
		if (pthread_cond_timedwait(&gpu->done_cv, &gpu->mu, &until) == ETIMEDOUT)
			break;
	}
	bool ok = gpu->grab_done && gpu->grab_ok;
	gpu->grab_dst = NULL;
	pthread_mutex_unlock(&gpu->mu);
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

	pthread_mutex_lock(&gpu->mu);
	pthread_cond_broadcast(&gpu->cv);
	pthread_cond_broadcast(&gpu->done_cv);
	pthread_mutex_unlock(&gpu->mu);

	if (gpu->thread_started) {
		pthread_join(gpu->thread, NULL);
		gpu->thread_started = false;
	}

	if (gpu->wl_egl_win) {
		g_lx.wl_egl_window_destroy(gpu->wl_egl_win);
		gpu->wl_egl_win = NULL;
	}
	if (gpu->wl_subsurf) {
		g_lx.wl_proxy_marshal(gpu->wl_subsurf, 0); /* destroy */
		g_lx.wl_proxy_destroy(gpu->wl_subsurf);
		gpu->wl_subsurf = NULL;
	}
	if (gpu->wl_surf) {
		g_lx.wl_proxy_marshal(gpu->wl_surf, 0); /* destroy */
		g_lx.wl_proxy_destroy(gpu->wl_surf);
		gpu->wl_surf = NULL;
	}
	if (gpu->wl_subcompositor) {
		g_lx.wl_proxy_marshal(gpu->wl_subcompositor, 0);
		g_lx.wl_proxy_destroy(gpu->wl_subcompositor);
		gpu->wl_subcompositor = NULL;
	}
	if (gpu->wl_compositor) {
		g_lx.wl_proxy_destroy(gpu->wl_compositor);
		gpu->wl_compositor = NULL;
	}
	if (gpu->wl_dpy)
		g_lx.wl_display_flush(gpu->wl_dpy);

	pthread_cond_destroy(&gpu->done_cv);
	pthread_cond_destroy(&gpu->cv);
	pthread_mutex_destroy(&gpu->mu);
	free(gpu);
}
