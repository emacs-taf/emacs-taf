/* etaf-video-mpv.c --- Cross-platform libmpv bridge for ETAF native video  -*- c-file-style: "linux" -*-

   Loads libmpv dynamically at runtime (macOS dylib, Linux so, Windows dll) so
   compilation requires only `emacs-module.h' and machines without libmpv fall
   back cleanly to the ffmpeg backend.  Uses `MPV_RENDER_API_TYPE_SW' with a
   64-byte aligned 4-byte pixel surface (`rgb0' / `bgr0') for fast SIMD scaling
   across macOS, Linux and Windows without platform-specific GPU contexts.

   Copyright (C) 2026  ETAF contributors

   This file is free software: you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by the
   Free Software Foundation, either version 3 of the License, or (at your
   option) any later version.  */

#ifndef _WIN32
#  ifdef __APPLE__
#    ifndef _DARWIN_C_SOURCE
#      define _DARWIN_C_SOURCE
#    endif
#  endif
#  ifndef _GNU_SOURCE
#    define _GNU_SOURCE
#  endif
#  ifndef _POSIX_C_SOURCE
#    define _POSIX_C_SOURCE 200809L
#  endif
#endif

#include <emacs-module.h>

#include <locale.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#  include <io.h>
#  include <malloc.h>
#  include "etaf-video-mpv-internal.h"
#  define etaf_dl_sym(lib, name) ((void *) GetProcAddress((lib), (name)))
#  define etaf_dl_close(lib) FreeLibrary(lib)
#  define etaf_unlink(path) _unlink(path)
static etaf_dl_t
etaf_dl_open (const char *path)
{
	if (!path || !path[0])
		return NULL;
	if (strchr(path, '\\') || strchr(path, '/')) {
		HMODULE h = LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
		if (h)
			return h;
	}
	return LoadLibraryA(path);
}
#else
#  include <dlfcn.h>
#  include <errno.h>
#  include <fcntl.h>
#  include <pthread.h>
#  include <time.h>
#  include <unistd.h>
#  include "etaf-video-mpv-internal.h"
#  define etaf_dl_open(path) dlopen((path), RTLD_LAZY | RTLD_LOCAL)
#  define etaf_dl_sym(lib, name) dlsym((lib), (name))
#  define etaf_dl_close(lib) dlclose(lib)
#  define etaf_unlink(path) unlink(path)
#endif

int plugin_is_GPL_compatible;

#if !defined(__APPLE__) && !defined(_WIN32) && !defined(__linux__)
bool etaf_mpv_gpu_platform_available (void) { return false; }
etaf_mpv_gpu *etaf_mpv_gpu_create (mpv_handle *mpv, const etaf_mpv_api *api)
{ (void) mpv; (void) api; return NULL; }
bool etaf_mpv_gpu_configure (etaf_mpv_gpu *gpu, uint64_t window_id,
                             const char *title_hint,
                             double outer_left, double outer_top,
                             double content_w, double content_h, bool is_child,
                             double x, double y, double w, double h, bool visible)
{
	(void) gpu; (void) window_id; (void) title_hint;
	(void) outer_left; (void) outer_top;
	(void) content_w; (void) content_h; (void) is_child;
	(void) x; (void) y; (void) w; (void) h; (void) visible;
	return false;
}
void etaf_mpv_gpu_request_redraw (etaf_mpv_gpu *gpu) { (void) gpu; }
uint64_t etaf_mpv_gpu_frame_count (etaf_mpv_gpu *gpu) { (void) gpu; return 0; }
bool etaf_mpv_gpu_grab_rgba (etaf_mpv_gpu *gpu, int width, int height, uint8_t *dst_rgba)
{ (void) gpu; (void) width; (void) height; (void) dst_rgba; return false; }
void etaf_mpv_gpu_destroy (etaf_mpv_gpu *gpu) { (void) gpu; }
#endif

static etaf_mpv_api g_mpv;

static bool
etaf_mpv_try_load_one (const char *path)
{
	if (!path || !path[0])
		return false;
	etaf_dl_t lib = etaf_dl_open(path);
	if (!lib)
		return false;

	etaf_mpv_api tmp;
	memset(&tmp, 0, sizeof tmp);
	tmp.lib = lib;

#define LOAD_SYM(field, sym)                                            \
	do {                                                            \
		*(void **) (&tmp.field) = etaf_dl_sym(lib, sym);        \
		if (!tmp.field) {                                       \
			etaf_dl_close(lib);                             \
			return false;                                   \
		}                                                       \
	} while (0)

	LOAD_SYM(client_api_version, "mpv_client_api_version");
	LOAD_SYM(error_string, "mpv_error_string");
	LOAD_SYM(free_fn, "mpv_free");
	LOAD_SYM(free_node_contents, "mpv_free_node_contents");
	LOAD_SYM(create, "mpv_create");
	LOAD_SYM(initialize, "mpv_initialize");
	LOAD_SYM(terminate_destroy, "mpv_terminate_destroy");
	LOAD_SYM(set_option_string, "mpv_set_option_string");
	LOAD_SYM(command, "mpv_command");
	LOAD_SYM(set_property, "mpv_set_property");
	LOAD_SYM(set_property_string, "mpv_set_property_string");
	LOAD_SYM(get_property, "mpv_get_property");
	LOAD_SYM(get_property_string, "mpv_get_property_string");
	LOAD_SYM(wait_event, "mpv_wait_event");
	LOAD_SYM(render_context_create, "mpv_render_context_create");
	LOAD_SYM(render_context_set_update_callback,
	         "mpv_render_context_set_update_callback");
	LOAD_SYM(render_context_update, "mpv_render_context_update");
	LOAD_SYM(render_context_render, "mpv_render_context_render");
	LOAD_SYM(render_context_report_swap, "mpv_render_context_report_swap");
	LOAD_SYM(render_context_free, "mpv_render_context_free");
#undef LOAD_SYM

	tmp.loaded = 1;
	g_mpv = tmp;
	return true;
}

static bool
etaf_mpv_ensure_loaded (const char *explicit_path)
{
	if (g_mpv.loaded)
		return true;
	if (explicit_path && etaf_mpv_try_load_one(explicit_path))
		return true;
	const char *env_path = getenv("ETAF_VIDEO_MPV_LIBRARY");
	if (env_path && etaf_mpv_try_load_one(env_path))
		return true;

#if defined(__APPLE__)
	/* First probe dylibs placed alongside this Emacs dynamic module itself.  */
	{
		Dl_info info;
		if (dladdr((void *) &etaf_mpv_try_load_one, &info) && info.dli_fname) {
			const char *slash = strrchr(info.dli_fname, '/');
			if (slash) {
				size_t dir_len = (size_t) (slash - info.dli_fname) + 1;
				static const char *const names[] = {
					"libmpv.2.dylib", "libmpv.dylib", NULL
				};
				for (int i = 0; names[i]; i++) {
					char full[1024];
					if (dir_len + strlen(names[i]) + 1 < sizeof full) {
						memcpy(full, info.dli_fname, dir_len);
						strcpy(full + dir_len, names[i]);
						if (etaf_mpv_try_load_one(full))
							return true;
					}
				}
			}
		}
	}
	static const char *const candidates[] = {
		"libmpv.2.dylib",
		"/opt/homebrew/lib/libmpv.2.dylib",
		"/usr/local/lib/libmpv.2.dylib",
		"libmpv.dylib",
		"/opt/homebrew/lib/libmpv.dylib",
		"/usr/local/lib/libmpv.dylib",
		NULL
	};
#elif defined(_WIN32)
	/* First probe DLLs placed alongside this Emacs dynamic module itself.  */
	{
		HMODULE self_mod = NULL;
		if (GetModuleHandleExA(
			    GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
			    | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
			    (LPCSTR) &etaf_mpv_try_load_one, &self_mod)
		    && self_mod) {
			char mod_dir[MAX_PATH];
			DWORD n = GetModuleFileNameA(self_mod, mod_dir, MAX_PATH);
			if (n > 0 && n < MAX_PATH) {
				char *slash = strrchr(mod_dir, '\\');
				char *fslash = strrchr(mod_dir, '/');
				if (fslash && (!slash || fslash > slash))
					slash = fslash;
				if (slash) {
					slash[1] = '\0';
					static const char *const names[] = {
						"libmpv-2.dll", "mpv-2.dll", "libmpv.dll", NULL
					};
					for (int i = 0; names[i]; i++) {
						char full[MAX_PATH + 32];
						snprintf(full, sizeof full, "%s%s", mod_dir, names[i]);
						if (etaf_mpv_try_load_one(full))
							return true;
					}
				}
			}
		}
	}
	static const char *const candidates[] = {
		"libmpv-2.dll",
		"mpv-2.dll",
		"libmpv.dll",
		"C:\\msys64\\ucrt64\\bin\\libmpv-2.dll",
		"C:\\msys64\\mingw64\\bin\\libmpv-2.dll",
		NULL
	};
#else
	/* First probe shared libraries placed alongside this dynamic module itself.  */
	{
		Dl_info info;
		if (dladdr((void *) &etaf_mpv_try_load_one, &info) && info.dli_fname) {
			const char *slash = strrchr(info.dli_fname, '/');
			if (slash) {
				size_t dir_len = (size_t) (slash - info.dli_fname) + 1;
				static const char *const names[] = {
					"libmpv.so.2", "libmpv.so.1", "libmpv.so", NULL
				};
				for (int i = 0; names[i]; i++) {
					char full[1024];
					if (dir_len + strlen(names[i]) + 1 < sizeof full) {
						memcpy(full, info.dli_fname, dir_len);
						strcpy(full + dir_len, names[i]);
						if (etaf_mpv_try_load_one(full))
							return true;
					}
				}
			}
		}
	}
	static const char *const candidates[] = {
		"libmpv.so.2",
		"libmpv.so.1",
		"libmpv.so",
		NULL
	};
#endif
	for (int i = 0; candidates[i]; i++) {
		if (etaf_mpv_try_load_one(candidates[i]))
			return true;
	}
	return false;
}

/* -------------------------------------------------------------------------
   Per-instance handle with aligned scratch buffers
   ------------------------------------------------------------------------- */

#define ETAF_MPV_RING_SLOTS 12

typedef struct {
	mpv_handle *mpv;
	mpv_render_context *render;
	etaf_mpv_gpu *gpu;
	atomic_int needs_render;
	int destroyed;
	uint8_t *sw_buf;
	size_t sw_cap;
	uint8_t *out_buf;
	size_t out_cap;
	atomic_int async_active;
#ifdef _WIN32
	HANDLE render_thread;
	CRITICAL_SECTION render_mu;
	CONDITION_VARIABLE render_cv;
#else
	pthread_t render_thread;
	pthread_mutex_t render_mu;
	pthread_cond_t render_cv;
#endif
	int async_stop;
	int async_dirty;
	int async_force;
	int async_w;
	int async_h;
	char async_prefix[512];
	int async_write_slot;
	int async_ready_slot;
	uint64_t async_ready_seq;
	uint64_t async_taken_seq;
	int async_pinned_a;
	int async_pinned_b;
	int64_t async_min_interval_ns;
	int64_t async_last_render_ns;
} etaf_mpv_ctx;

#ifdef _WIN32
static inline void etaf_mu_lock (etaf_mpv_ctx *c) { EnterCriticalSection(&c->render_mu); }
static inline void etaf_mu_unlock (etaf_mpv_ctx *c) { LeaveCriticalSection(&c->render_mu); }
static inline void etaf_cv_signal (etaf_mpv_ctx *c) { WakeConditionVariable(&c->render_cv); }
#else
static inline void etaf_mu_lock (etaf_mpv_ctx *c) { pthread_mutex_lock(&c->render_mu); }
static inline void etaf_mu_unlock (etaf_mpv_ctx *c) { pthread_mutex_unlock(&c->render_mu); }
static inline void etaf_cv_signal (etaf_mpv_ctx *c) { pthread_cond_signal(&c->render_cv); }
#endif

static void *
etaf_aligned_alloc64 (size_t size)
{
	if (size == 0)
		return NULL;
#ifdef _WIN32
	return _aligned_malloc(size, 64);
#else
	void *p = NULL;
	if (posix_memalign(&p, 64, size) != 0)
		return NULL;
	return p;
#endif
}

static void
etaf_aligned_free64 (void *p)
{
	if (!p)
		return;
#ifdef _WIN32
	_aligned_free(p);
#else
	free(p);
#endif
}

static bool
etaf_mpv_ensure_sw_buf (etaf_mpv_ctx *ctx, size_t need)
{
	if (ctx->sw_cap >= need)
		return true;
	uint8_t *buf = etaf_aligned_alloc64(need);
	if (!buf)
		return false;
	etaf_aligned_free64(ctx->sw_buf);
	ctx->sw_buf = buf;
	ctx->sw_cap = need;
	return true;
}

static bool
etaf_mpv_ensure_out_buf (etaf_mpv_ctx *ctx, size_t need)
{
	if (ctx->out_cap >= need)
		return true;
	uint8_t *buf = malloc(need);
	if (!buf)
		return false;
	free(ctx->out_buf);
	ctx->out_buf = buf;
	ctx->out_cap = need;
	return true;
}

static void
etaf_mpv_on_render_update (void *cb_ctx)
{
	etaf_mpv_ctx *ctx = (etaf_mpv_ctx *) cb_ctx;
	if (!ctx)
		return;
	atomic_store_explicit(&ctx->needs_render, 1, memory_order_release);
	if (atomic_load_explicit(&ctx->async_active, memory_order_acquire)) {
		etaf_mu_lock(ctx);
		ctx->async_dirty = 1;
		etaf_cv_signal(ctx);
		etaf_mu_unlock(ctx);
	}
}

static void
etaf_mpv_teardown (etaf_mpv_ctx *ctx)
{
	if (!ctx || ctx->destroyed)
		return;
	ctx->destroyed = 1;
	if (ctx->render)
		g_mpv.render_context_set_update_callback(ctx->render, NULL, NULL);
	if (atomic_exchange_explicit(&ctx->async_active, 0, memory_order_acq_rel)) {
		etaf_mu_lock(ctx);
		ctx->async_stop = 1;
		etaf_cv_signal(ctx);
		etaf_mu_unlock(ctx);
#ifdef _WIN32
		if (ctx->render_thread) {
			WaitForSingleObject(ctx->render_thread, 4000);
			CloseHandle(ctx->render_thread);
			ctx->render_thread = NULL;
		}
		DeleteCriticalSection(&ctx->render_mu);
#else
		pthread_join(ctx->render_thread, NULL);
		pthread_cond_destroy(&ctx->render_cv);
		pthread_mutex_destroy(&ctx->render_mu);
#endif
		for (int i = 0; i < ETAF_MPV_RING_SLOTS; i++) {
			char path[560];
			snprintf(path, sizeof path, "%s-%d.tif", ctx->async_prefix, i);
			etaf_unlink(path);
		}
	}
	if (ctx->gpu) {
		etaf_mpv_gpu_destroy(ctx->gpu);
		ctx->gpu = NULL;
	}
	if (ctx->render) {
		g_mpv.render_context_free(ctx->render);
		ctx->render = NULL;
	}
	if (ctx->mpv) {
		g_mpv.terminate_destroy(ctx->mpv);
		ctx->mpv = NULL;
	}
	etaf_aligned_free64(ctx->sw_buf);
	ctx->sw_buf = NULL;
	ctx->sw_cap = 0;
	free(ctx->out_buf);
	ctx->out_buf = NULL;
	ctx->out_cap = 0;
}

static void
etaf_mpv_finalize (void *ptr)
{
	etaf_mpv_ctx *ctx = (etaf_mpv_ctx *) ptr;
	if (ctx) {
		etaf_mpv_teardown(ctx);
		free(ctx);
	}
}

/* -------------------------------------------------------------------------
   Emacs value conversion helpers
   ------------------------------------------------------------------------- */

static char *
etaf_copy_lisp_string (emacs_env *env, emacs_value val)
{
	ptrdiff_t size = 0;
	if (!env->copy_string_contents(env, val, NULL, &size) || size <= 0)
		return NULL;
	char *buf = malloc((size_t) size);
	if (!buf)
		return NULL;
	if (!env->copy_string_contents(env, val, buf, &size)) {
		free(buf);
		return NULL;
	}
	return buf;
}

static emacs_value
etaf_intern (emacs_env *env, const char *name)
{
	return env->intern(env, name);
}

static emacs_value
etaf_cons (emacs_env *env, emacs_value car, emacs_value cdr)
{
	emacs_value args[2] = { car, cdr };
	return env->funcall(env, etaf_intern(env, "cons"), 2, args);
}

static emacs_value
etaf_make_str (emacs_env *env, const char *s)
{
	if (!s)
		return etaf_intern(env, "nil");
	return env->make_string(env, s, (ptrdiff_t) strlen(s));
}

static etaf_mpv_ctx *
etaf_extract_ctx (emacs_env *env, emacs_value arg)
{
	etaf_mpv_ctx *ctx = (etaf_mpv_ctx *) env->get_user_ptr(env, arg);
	if (!ctx || ctx->destroyed || !ctx->mpv)
		return NULL;
	return ctx;
}

static emacs_value
etaf_mpv_node_to_lisp (emacs_env *env, const etaf_mpv_node *node)
{
	emacs_value Qnil = etaf_intern(env, "nil");
	emacs_value Qt = etaf_intern(env, "t");
	if (!node)
		return Qnil;
	switch (node->format) {
	case ETAF_MPV_FORMAT_NONE:
		return Qnil;
	case ETAF_MPV_FORMAT_STRING:
	case ETAF_MPV_FORMAT_OSD_STRING:
		return etaf_make_str(env, node->u.string);
	case ETAF_MPV_FORMAT_FLAG:
		return node->u.flag ? Qt : Qnil;
	case ETAF_MPV_FORMAT_INT64:
		return env->make_integer(env, node->u.int64);
	case ETAF_MPV_FORMAT_DOUBLE:
		return env->make_float(env, node->u.double_);
	case ETAF_MPV_FORMAT_NODE_ARRAY: {
		etaf_mpv_node_list *list = node->u.list;
		emacs_value acc = Qnil;
		if (!list)
			return Qnil;
		for (int i = list->num - 1; i >= 0; i--) {
			emacs_value item = etaf_mpv_node_to_lisp(env, &list->values[i]);
			acc = etaf_cons(env, item, acc);
		}
		return acc;
	}
	case ETAF_MPV_FORMAT_NODE_MAP: {
		etaf_mpv_node_list *list = node->u.list;
		emacs_value acc = Qnil;
		if (!list)
			return Qnil;
		for (int i = list->num - 1; i >= 0; i--) {
			emacs_value k = etaf_make_str(env, list->keys[i]);
			emacs_value v = etaf_mpv_node_to_lisp(env, &list->values[i]);
			acc = etaf_cons(env, etaf_cons(env, k, v), acc);
		}
		return acc;
	}
	case ETAF_MPV_FORMAT_BYTE_ARRAY:
		if (node->u.ba && node->u.ba->data)
			return env->make_unibyte_string(
				env, (const char *) node->u.ba->data,
				(ptrdiff_t) node->u.ba->size);
		return Qnil;
	default:
		return Qnil;
	}
}

/* -------------------------------------------------------------------------
   Exported Emacs module functions
   ------------------------------------------------------------------------- */

static emacs_value
f_available_p (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) data;
	char *path = NULL;
	if (nargs >= 1 && env->is_not_nil(env, args[0]))
		path = etaf_copy_lisp_string(env, args[0]);
	bool ok = etaf_mpv_ensure_loaded(path);
	free(path);
	return etaf_intern(env, ok ? "t" : "nil");
}

static emacs_value
f_version (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) args; (void) data;
	if (!etaf_mpv_ensure_loaded(NULL))
		return etaf_intern(env, "nil");
	return env->make_integer(env, (intmax_t) g_mpv.client_api_version());
}

static mpv_handle *
etaf_mpv_init_handle (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                      const char *default_hwdec)
{
	/* libmpv requires LC_NUMERIC="C" before mpv_initialize.  */
	setlocale(LC_NUMERIC, "C");

	mpv_handle *mpv = g_mpv.create();
	if (!mpv)
		return NULL;

	/* Sensible, isolated defaults for embedded playback.  */
	g_mpv.set_option_string(mpv, "vo", "libmpv");
	g_mpv.set_option_string(mpv, "hwdec", default_hwdec);
	g_mpv.set_option_string(mpv, "video-timing-offset", "0");
	g_mpv.set_option_string(mpv, "idle", "yes");
	g_mpv.set_option_string(mpv, "keep-open", "yes");
	g_mpv.set_option_string(mpv, "osc", "no");
	g_mpv.set_option_string(mpv, "osd-level", "0");
	g_mpv.set_option_string(mpv, "terminal", "no");
	g_mpv.set_option_string(mpv, "config", "no");
	g_mpv.set_option_string(mpv, "input-default-bindings", "no");
	g_mpv.set_option_string(mpv, "input-vo-keyboard", "no");
	g_mpv.set_option_string(mpv, "sub-auto", "fuzzy");
	g_mpv.set_option_string(mpv, "ytdl", "yes");
	g_mpv.set_option_string(mpv, "audio-client-name", "ETAF Video Player");

	/* Apply caller-provided (KEY . VALUE) string options before init.  */
	if (nargs >= 1 && env->is_not_nil(env, args[0])) {
		emacs_value cur = args[0];
		emacs_value Fcar = etaf_intern(env, "car");
		emacs_value Fcdr = etaf_intern(env, "cdr");
		emacs_value Fconsp = etaf_intern(env, "consp");
		while (env->is_not_nil(env, env->funcall(env, Fconsp, 1, &cur))) {
			emacs_value pair = env->funcall(env, Fcar, 1, &cur);
			cur = env->funcall(env, Fcdr, 1, &cur);
			if (env->is_not_nil(env, env->funcall(env, Fconsp, 1, &pair))) {
				char *k = etaf_copy_lisp_string(env, env->funcall(env, Fcar, 1, &pair));
				char *v = etaf_copy_lisp_string(env, env->funcall(env, Fcdr, 1, &pair));
				if (k && v)
					g_mpv.set_option_string(mpv, k, v);
				free(k);
				free(v);
			}
		}
	}

	if (g_mpv.initialize(mpv) < 0) {
		g_mpv.terminate_destroy(mpv);
		return NULL;
	}
	return mpv;
}

static emacs_value
f_create (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	if (!etaf_mpv_ensure_loaded(NULL))
		return Qnil;

	mpv_handle *mpv = etaf_mpv_init_handle(env, nargs, args, "auto-copy");
	if (!mpv)
		return Qnil;

	etaf_mpv_ctx *ctx = calloc(1, sizeof *ctx);
	if (!ctx) {
		g_mpv.terminate_destroy(mpv);
		return Qnil;
	}
	ctx->mpv = mpv;
	atomic_init(&ctx->needs_render, 0);
	atomic_init(&ctx->async_active, 0);

	etaf_mpv_render_param params[] = {
		{ ETAF_MPV_RP_API_TYPE, (void *) "sw" },
		{ ETAF_MPV_RP_INVALID, NULL }
	};
	if (g_mpv.render_context_create(&ctx->render, mpv, params) < 0) {
		etaf_mpv_teardown(ctx);
		free(ctx);
		return Qnil;
	}
	g_mpv.render_context_set_update_callback(
		ctx->render, etaf_mpv_on_render_update, ctx);

	return env->make_user_ptr(env, etaf_mpv_finalize, ctx);
}

static emacs_value
f_gpu_available_p (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) args; (void) data;
	bool ok = etaf_mpv_ensure_loaded(NULL) && etaf_mpv_gpu_platform_available();
	return etaf_intern(env, ok ? "t" : "nil");
}

static emacs_value
f_create_gpu (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	if (!etaf_mpv_ensure_loaded(NULL) || !etaf_mpv_gpu_platform_available())
		return Qnil;

	mpv_handle *mpv = etaf_mpv_init_handle(
		env, nargs, args,
#ifdef __APPLE__
		"videotoolbox"
#else
		"auto-safe"
#endif
	);
	if (!mpv)
		return Qnil;

	etaf_mpv_ctx *ctx = calloc(1, sizeof *ctx);
	if (!ctx) {
		g_mpv.terminate_destroy(mpv);
		return Qnil;
	}
	ctx->mpv = mpv;
	atomic_init(&ctx->needs_render, 0);
	atomic_init(&ctx->async_active, 0);

	ctx->gpu = etaf_mpv_gpu_create(mpv, &g_mpv);
	if (!ctx->gpu) {
		etaf_mpv_teardown(ctx);
		free(ctx);
		return Qnil;
	}
	return env->make_user_ptr(env, etaf_mpv_finalize, ctx);
}

static emacs_value
f_destroy (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	etaf_mpv_ctx *ctx = (etaf_mpv_ctx *) env->get_user_ptr(env, args[0]);
	if (ctx)
		etaf_mpv_teardown(ctx);
	return etaf_intern(env, "t");
}

static emacs_value
f_command (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx)
		return etaf_cons(env, env->make_integer(env, -3),
		                 etaf_make_str(env, "uninitialized"));

	emacs_value Flength = etaf_intern(env, "length");
	emacs_value Fcar = etaf_intern(env, "car");
	emacs_value Fcdr = etaf_intern(env, "cdr");
	emacs_value list = args[1];
	intmax_t len = env->extract_integer(env, env->funcall(env, Flength, 1, &list));
	if (len <= 0 || len > 64)
		return etaf_cons(env, env->make_integer(env, -4),
		                 etaf_make_str(env, "invalid command length"));

	char **cargs = calloc((size_t) len + 1, sizeof(char *));
	if (!cargs)
		return etaf_cons(env, env->make_integer(env, -2),
		                 etaf_make_str(env, "out of memory"));

	emacs_value cur = list;
	for (intmax_t i = 0; i < len; i++) {
		emacs_value item = env->funcall(env, Fcar, 1, &cur);
		cur = env->funcall(env, Fcdr, 1, &cur);
		cargs[i] = etaf_copy_lisp_string(env, item);
		if (!cargs[i]) {
			for (intmax_t j = 0; j < i; j++)
				free(cargs[j]);
			free(cargs);
			return etaf_cons(env, env->make_integer(env, -4),
			                 etaf_make_str(env, "command args must be strings"));
		}
	}

	int rc = g_mpv.command(ctx->mpv, (const char **) cargs);
	for (intmax_t i = 0; i < len; i++)
		free(cargs[i]);
	free(cargs);

	if (rc >= 0)
		return env->make_integer(env, 0);
	return etaf_cons(env, env->make_integer(env, rc),
	                 etaf_make_str(env, g_mpv.error_string(rc)));
}

static emacs_value
f_set_property (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx)
		return etaf_intern(env, "nil");
	char *name = etaf_copy_lisp_string(env, args[1]);
	if (!name)
		return etaf_intern(env, "nil");

	emacs_value val = args[2];
	emacs_value type = env->type_of(env, val);
	int rc;
	if (!env->is_not_nil(env, val)) {
		int flag = 0;
		rc = g_mpv.set_property(ctx->mpv, name, ETAF_MPV_FORMAT_FLAG, &flag);
	} else if (env->eq(env, val, etaf_intern(env, "t"))) {
		int flag = 1;
		rc = g_mpv.set_property(ctx->mpv, name, ETAF_MPV_FORMAT_FLAG, &flag);
	} else if (env->eq(env, type, etaf_intern(env, "integer"))) {
		int64_t n = (int64_t) env->extract_integer(env, val);
		rc = g_mpv.set_property(ctx->mpv, name, ETAF_MPV_FORMAT_INT64, &n);
	} else if (env->eq(env, type, etaf_intern(env, "float"))) {
		double d = env->extract_float(env, val);
		rc = g_mpv.set_property(ctx->mpv, name, ETAF_MPV_FORMAT_DOUBLE, &d);
	} else {
		char *s = etaf_copy_lisp_string(env, val);
		if (!s) {
			free(name);
			return etaf_intern(env, "nil");
		}
		rc = g_mpv.set_property_string(ctx->mpv, name, s);
		free(s);
	}
	free(name);
	if (rc >= 0)
		return etaf_intern(env, "t");
	return etaf_cons(env, env->make_integer(env, rc),
	                 etaf_make_str(env, g_mpv.error_string(rc)));
}

static emacs_value
f_get_property (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx)
		return Qnil;
	char *name = etaf_copy_lisp_string(env, args[1]);
	if (!name)
		return Qnil;

	emacs_value kind = (nargs >= 3 && env->is_not_nil(env, args[2]))
		? args[2] : etaf_intern(env, "node");
	emacs_value out = Qnil;

	if (env->eq(env, kind, etaf_intern(env, "string"))) {
		char *s = g_mpv.get_property_string(ctx->mpv, name);
		if (s) {
			out = etaf_make_str(env, s);
			g_mpv.free_fn(s);
		}
	} else if (env->eq(env, kind, etaf_intern(env, "bool"))) {
		int flag = 0;
		if (g_mpv.get_property(ctx->mpv, name, ETAF_MPV_FORMAT_FLAG, &flag) >= 0)
			out = etaf_intern(env, flag ? "t" : "nil");
	} else if (env->eq(env, kind, etaf_intern(env, "int"))) {
		int64_t n = 0;
		if (g_mpv.get_property(ctx->mpv, name, ETAF_MPV_FORMAT_INT64, &n) >= 0)
			out = env->make_integer(env, (intmax_t) n);
	} else if (env->eq(env, kind, etaf_intern(env, "float"))) {
		double d = 0.0;
		if (g_mpv.get_property(ctx->mpv, name, ETAF_MPV_FORMAT_DOUBLE, &d) >= 0)
			out = env->make_float(env, d);
	} else {
		etaf_mpv_node node;
		memset(&node, 0, sizeof node);
		if (g_mpv.get_property(ctx->mpv, name, ETAF_MPV_FORMAT_NODE, &node) >= 0) {
			out = etaf_mpv_node_to_lisp(env, &node);
			g_mpv.free_node_contents(&node);
		}
	}
	free(name);
	return out;
}

static emacs_value
f_poll_events (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx)
		return Qnil;

	emacs_value Flist = etaf_intern(env, "list");
	emacs_value acc = Qnil;
	for (int guard = 0; guard < 128; guard++) {
		etaf_mpv_event *ev = g_mpv.wait_event(ctx->mpv, 0.0);
		if (!ev || ev->event_id == ETAF_MPV_EVENT_NONE)
			break;
		emacs_value entry = Qnil;
		switch (ev->event_id) {
		case ETAF_MPV_EVENT_START_FILE: {
			emacs_value a[2] = { etaf_intern(env, ":event"),
			                     etaf_intern(env, "start-file") };
			entry = env->funcall(env, Flist, 2, a);
			break;
		}
		case ETAF_MPV_EVENT_FILE_LOADED: {
			emacs_value a[2] = { etaf_intern(env, ":event"),
			                     etaf_intern(env, "file-loaded") };
			entry = env->funcall(env, Flist, 2, a);
			break;
		}
		case ETAF_MPV_EVENT_VIDEO_RECONFIG: {
			emacs_value a[2] = { etaf_intern(env, ":event"),
			                     etaf_intern(env, "video-reconfig") };
			entry = env->funcall(env, Flist, 2, a);
			break;
		}
		case ETAF_MPV_EVENT_SEEK: {
			emacs_value a[2] = { etaf_intern(env, ":event"),
			                     etaf_intern(env, "seek") };
			entry = env->funcall(env, Flist, 2, a);
			break;
		}
		case ETAF_MPV_EVENT_PLAYBACK_RESTART: {
			emacs_value a[2] = { etaf_intern(env, ":event"),
			                     etaf_intern(env, "playback-restart") };
			entry = env->funcall(env, Flist, 2, a);
			break;
		}
		case ETAF_MPV_EVENT_END_FILE: {
			etaf_mpv_event_end_file *ef = (etaf_mpv_event_end_file *) ev->data;
			const char *reason = "other";
			emacs_value err_val = Qnil;
			if (ef) {
				switch (ef->reason) {
				case ETAF_MPV_END_EOF: reason = "eof"; break;
				case ETAF_MPV_END_STOP: reason = "stop"; break;
				case ETAF_MPV_END_QUIT: reason = "quit"; break;
				case ETAF_MPV_END_ERROR:
					reason = "error";
					if (ef->error < 0)
						err_val = etaf_make_str(
							env, g_mpv.error_string(ef->error));
					break;
				case ETAF_MPV_END_REDIRECT: reason = "redirect"; break;
				}
			}
			emacs_value a[6] = {
				etaf_intern(env, ":event"), etaf_intern(env, "end-file"),
				etaf_intern(env, ":reason"), etaf_intern(env, reason),
				etaf_intern(env, ":error"), err_val
			};
			entry = env->funcall(env, Flist, 6, a);
			break;
		}
		case ETAF_MPV_EVENT_SHUTDOWN: {
			emacs_value a[2] = { etaf_intern(env, ":event"),
			                     etaf_intern(env, "shutdown") };
			entry = env->funcall(env, Flist, 2, a);
			break;
		}
		default:
			break;
		}
		if (env->is_not_nil(env, entry))
			acc = etaf_cons(env, entry, acc);
	}
	return env->funcall(env, etaf_intern(env, "nreverse"), 1, &acc);
}

static emacs_value
f_frame_ready_p (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !ctx->render)
		return etaf_intern(env, "nil");
	if (atomic_exchange_explicit(&ctx->needs_render, 0, memory_order_acq_rel)) {
		uint64_t flags = g_mpv.render_context_update(ctx->render);
		if (flags & ETAF_MPV_RENDER_UPDATE_FRAME)
			return etaf_intern(env, "t");
	}
	return etaf_intern(env, "nil");
}

static bool
etaf_mpv_render_sw (etaf_mpv_ctx *ctx, int width, int height,
                    const char *fmt, size_t *out_stride)
{
	size_t stride = (((size_t) width * 4u) + 63u) & ~(size_t) 63u;
	size_t need = stride * (size_t) height;
	if (!etaf_mpv_ensure_sw_buf(ctx, need))
		return false;

	int size[2] = { width, height };
	int block = 0;
	etaf_mpv_render_param params[] = {
		{ ETAF_MPV_RP_SW_SIZE, size },
		{ ETAF_MPV_RP_SW_FORMAT, (void *) fmt },
		{ ETAF_MPV_RP_SW_STRIDE, &stride },
		{ ETAF_MPV_RP_SW_POINTER, ctx->sw_buf },
		{ ETAF_MPV_RP_BLOCK_FOR_TARGET_TIME, &block },
		{ ETAF_MPV_RP_INVALID, NULL }
	};
	int rc = g_mpv.render_context_render(ctx->render, params);
	if (rc < 0)
		return false;
	g_mpv.render_context_report_swap(ctx->render);
	*out_stride = stride;
	return true;
}

static emacs_value
f_render_ppm (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !ctx->render)
		return Qnil;
	int width = (int) env->extract_integer(env, args[1]);
	int height = (int) env->extract_integer(env, args[2]);
	if (width <= 0 || height <= 0 || width > 8192 || height > 8192)
		return Qnil;

	size_t stride = 0;
	if (!etaf_mpv_render_sw(ctx, width, height, "rgb0", &stride))
		return Qnil;

	char header[48];
	int hlen = snprintf(header, sizeof header, "P6\n%d %d\n255\n", width, height);
	if (hlen <= 0)
		return Qnil;

	size_t total = (size_t) hlen + (size_t) width * (size_t) height * 3u;
	if (!etaf_mpv_ensure_out_buf(ctx, total))
		return Qnil;

	memcpy(ctx->out_buf, header, (size_t) hlen);
	uint8_t *dst = ctx->out_buf + hlen;
	for (int y = 0; y < height; y++) {
		const uint8_t *src = ctx->sw_buf + (size_t) y * stride;
		for (int x = 0; x < width; x++) {
			dst[0] = src[0];
			dst[1] = src[1];
			dst[2] = src[2];
			dst += 3;
			src += 4;
		}
	}
	return env->make_unibyte_string(env, (const char *) ctx->out_buf,
	                                (ptrdiff_t) total);
}

static inline void
etaf_put_u16_le (uint8_t *p, uint16_t v)
{
	p[0] = (uint8_t) (v & 0xffu);
	p[1] = (uint8_t) ((v >> 8) & 0xffu);
}

static inline void
etaf_put_u32_le (uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t) (v & 0xffu);
	p[1] = (uint8_t) ((v >> 8) & 0xffu);
	p[2] = (uint8_t) ((v >> 16) & 0xffu);
	p[3] = (uint8_t) ((v >> 24) & 0xffu);
}

static inline void
etaf_put_tiff_entry (uint8_t *p, uint16_t tag, uint16_t type,
                     uint32_t count, uint32_t value)
{
	etaf_put_u16_le(p + 0, tag);
	etaf_put_u16_le(p + 2, type);
	etaf_put_u32_le(p + 4, count);
	etaf_put_u32_le(p + 8, value);
}

static bool
etaf_mpv_pack_rgb24_tiff (etaf_mpv_ctx *ctx, const uint8_t *src_rgba,
                          size_t stride, int width, int height,
                          size_t *out_total)
{
	/* Minimal uncompressed 24-bit RGB Baseline TIFF (128-byte header).
	   Emacs's native TIFF/ImageIO loader decodes this ~4.5x faster than
	   P6 PPM while staying 100% lossless.  */
	const size_t data_off = 128u;
	size_t img_bytes = (size_t) width * (size_t) height * 3u;
	size_t total = data_off + img_bytes;
	if (!etaf_mpv_ensure_out_buf(ctx, total))
		return false;

	uint8_t *hdr = ctx->out_buf;
	memset(hdr, 0, data_off);
	hdr[0] = 'I';
	hdr[1] = 'I';
	etaf_put_u16_le(hdr + 2, 42u);
	etaf_put_u32_le(hdr + 4, 8u);   /* IFD offset */
	etaf_put_u16_le(hdr + 8, 9u);   /* 9 directory entries */
	uint8_t *e = hdr + 10;
	etaf_put_tiff_entry(e + 0 * 12, 256u, 4u, 1u, (uint32_t) width);     /* ImageWidth */
	etaf_put_tiff_entry(e + 1 * 12, 257u, 4u, 1u, (uint32_t) height);    /* ImageLength */
	etaf_put_tiff_entry(e + 2 * 12, 258u, 3u, 3u, 122u);                 /* BitsPerSample -> [8,8,8] */
	etaf_put_tiff_entry(e + 3 * 12, 259u, 3u, 1u, 1u);                   /* Compression = None */
	etaf_put_tiff_entry(e + 4 * 12, 262u, 3u, 1u, 2u);                   /* Photometric = RGB */
	etaf_put_tiff_entry(e + 5 * 12, 273u, 4u, 1u, (uint32_t) data_off);  /* StripOffsets */
	etaf_put_tiff_entry(e + 6 * 12, 277u, 3u, 1u, 3u);                   /* SamplesPerPixel = 3 */
	etaf_put_tiff_entry(e + 7 * 12, 278u, 4u, 1u, (uint32_t) height);    /* RowsPerStrip */
	etaf_put_tiff_entry(e + 8 * 12, 279u, 4u, 1u, (uint32_t) img_bytes); /* StripByteCounts */
	etaf_put_u32_le(hdr + 118, 0u); /* Next IFD = 0 */
	etaf_put_u16_le(hdr + 122, 8u);
	etaf_put_u16_le(hdr + 124, 8u);
	etaf_put_u16_le(hdr + 126, 8u);

	uint8_t *dst = ctx->out_buf + data_off;
	for (int y = 0; y < height; y++) {
		const uint8_t *src = src_rgba + (size_t) y * stride;
		int x = 0;
		for (; x + 4 <= width; x += 4) {
			dst[0]  = src[0];  dst[1]  = src[1];  dst[2]  = src[2];
			dst[3]  = src[4];  dst[4]  = src[5];  dst[5]  = src[6];
			dst[6]  = src[8];  dst[7]  = src[9];  dst[8]  = src[10];
			dst[9]  = src[12]; dst[10] = src[13]; dst[11] = src[14];
			dst += 12;
			src += 16;
		}
		for (; x < width; x++) {
			dst[0] = src[0];
			dst[1] = src[1];
			dst[2] = src[2];
			dst += 3;
			src += 4;
		}
	}
	*out_total = total;
	return true;
}

static bool
etaf_mpv_encode_tiff (etaf_mpv_ctx *ctx, int width, int height, size_t *out_total)
{
	size_t stride = 0;
	if (!etaf_mpv_render_sw(ctx, width, height, "rgb0", &stride))
		return false;
	return etaf_mpv_pack_rgb24_tiff(ctx, ctx->sw_buf, stride, width, height, out_total);
}

static emacs_value
f_render_tiff (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !ctx->render)
		return Qnil;
	if (atomic_load_explicit(&ctx->async_active, memory_order_acquire))
		return Qnil;
	int width = (int) env->extract_integer(env, args[1]);
	int height = (int) env->extract_integer(env, args[2]);
	if (width <= 0 || height <= 0 || width > 8192 || height > 8192)
		return Qnil;

	size_t total = 0;
	if (!etaf_mpv_encode_tiff(ctx, width, height, &total))
		return Qnil;
	return env->make_unibyte_string(env, (const char *) ctx->out_buf,
	                                (ptrdiff_t) total);
}

static bool
etaf_mpv_write_all_file (const char *path, const uint8_t *buf, size_t len)
{
#ifdef _WIN32
	FILE *fp = fopen(path, "wb");
	if (!fp)
		return false;
	size_t written = fwrite(buf, 1, len, fp);
	int rc = fclose(fp);
	return written == len && rc == 0;
#else
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		return false;
	size_t off = 0;
	while (off < len) {
		ssize_t n = write(fd, buf + off, len - off);
		if (n > 0) {
			off += (size_t) n;
			continue;
		}
		if (n < 0 && errno == EINTR)
			continue;
		close(fd);
		return false;
	}
	return close(fd) == 0;
#endif
}

static emacs_value
f_render_tiff_file (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !ctx->render)
		return Qnil;
	if (atomic_load_explicit(&ctx->async_active, memory_order_acquire))
		return Qnil;
	char *path = etaf_copy_lisp_string(env, args[1]);
	int width = (int) env->extract_integer(env, args[2]);
	int height = (int) env->extract_integer(env, args[3]);
	if (!path || width <= 0 || height <= 0 || width > 8192 || height > 8192) {
		free(path);
		return Qnil;
	}
	size_t total = 0;
	bool ok = etaf_mpv_encode_tiff(ctx, width, height, &total)
		&& etaf_mpv_write_all_file(path, ctx->out_buf, total);
	free(path);
	return ok ? etaf_intern(env, "t") : Qnil;
}

static int64_t
etaf_monotonic_ns (void)
{
#ifdef _WIN32
	LARGE_INTEGER freq, now;
	QueryPerformanceFrequency(&freq);
	QueryPerformanceCounter(&now);
	if (freq.QuadPart <= 0)
		return 0;
	return (int64_t) (((double) now.QuadPart * 1000000000.0) / (double) freq.QuadPart);
#else
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t) ts.tv_sec * 1000000000LL + (int64_t) ts.tv_nsec;
#endif
}

static void
etaf_mpv_render_worker_body (etaf_mpv_ctx *ctx)
{
	for (;;) {
		etaf_mu_lock(ctx);
		while (!ctx->async_stop && !ctx->async_dirty && !ctx->async_force) {
#ifdef _WIN32
			SleepConditionVariableCS(&ctx->render_cv, &ctx->render_mu, INFINITE);
#else
			pthread_cond_wait(&ctx->render_cv, &ctx->render_mu);
#endif
		}
		if (ctx->async_stop) {
			etaf_mu_unlock(ctx);
			break;
		}
		if (!ctx->async_force && ctx->async_min_interval_ns > 0
		    && ctx->async_last_render_ns > 0) {
			int64_t now_ns = etaf_monotonic_ns();
			int64_t rem_ns = (ctx->async_last_render_ns + ctx->async_min_interval_ns) - now_ns;
			if (rem_ns > 1000000LL) {
				if (rem_ns > 100000000LL)
					rem_ns = 100000000LL;
#ifdef _WIN32
				DWORD ms = (DWORD) ((rem_ns + 999999LL) / 1000000LL);
				if (ms == 0) ms = 1;
				SleepConditionVariableCS(&ctx->render_cv, &ctx->render_mu, ms);
#else
				struct timespec until;
				clock_gettime(CLOCK_REALTIME, &until);
				until.tv_sec += (time_t) (rem_ns / 1000000000LL);
				until.tv_nsec += (long) (rem_ns % 1000000000LL);
				if (until.tv_nsec >= 1000000000L) {
					until.tv_sec += 1;
					until.tv_nsec -= 1000000000L;
				}
				pthread_cond_timedwait(&ctx->render_cv, &ctx->render_mu, &until);
#endif
				if (ctx->async_stop) {
					etaf_mu_unlock(ctx);
					break;
				}
			}
		}
		int force = ctx->async_force;
		ctx->async_dirty = 0;
		ctx->async_force = 0;
		int w = ctx->async_w;
		int h = ctx->async_h;
		int pinned_a = ctx->async_pinned_a;
		int pinned_b = ctx->async_pinned_b;
		int ready = ctx->async_ready_slot;
		int slot = ctx->async_write_slot;
		for (int tries = 0; tries < ETAF_MPV_RING_SLOTS; tries++) {
			if (slot != pinned_a && slot != pinned_b && slot != ready)
				break;
			slot = (slot + 1) % ETAF_MPV_RING_SLOTS;
		}
		ctx->async_write_slot = (slot + 1) % ETAF_MPV_RING_SLOTS;
		etaf_mu_unlock(ctx);

		uint64_t flags = g_mpv.render_context_update(ctx->render);
		if ((flags & ETAF_MPV_RENDER_UPDATE_FRAME) || force) {
			int64_t start_ns = etaf_monotonic_ns();
			char path[560];
			snprintf(path, sizeof path, "%s-%d.tif", ctx->async_prefix, slot);
			size_t total = 0;
			if (etaf_mpv_encode_tiff(ctx, w, h, &total)
			    && etaf_mpv_write_all_file(path, ctx->out_buf, total)) {
				etaf_mu_lock(ctx);
				ctx->async_ready_slot = slot;
				ctx->async_ready_seq++;
				ctx->async_last_render_ns = start_ns;
				etaf_mu_unlock(ctx);
			}
		}
	}
}

#ifdef _WIN32
static DWORD WINAPI
etaf_mpv_render_worker_win32 (LPVOID arg)
{
	etaf_mpv_render_worker_body((etaf_mpv_ctx *) arg);
	return 0;
}
#else
static void *
etaf_mpv_render_worker (void *arg)
{
	etaf_mpv_render_worker_body((etaf_mpv_ctx *) arg);
	return NULL;
}
#endif

static emacs_value
f_async_start (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !ctx->render)
		return Qnil;
	if (atomic_load_explicit(&ctx->async_active, memory_order_acquire))
		return etaf_intern(env, "t");
	char *prefix = etaf_copy_lisp_string(env, args[1]);
	int width = (int) env->extract_integer(env, args[2]);
	int height = (int) env->extract_integer(env, args[3]);
	int max_fps = 0;
	if (nargs >= 5 && env->is_not_nil(env, args[4]))
		max_fps = (int) env->extract_integer(env, args[4]);
	if (!prefix || strlen(prefix) >= sizeof ctx->async_prefix - 16
	    || width <= 0 || height <= 0 || width > 8192 || height > 8192) {
		free(prefix);
		return Qnil;
	}
#ifdef _WIN32
	InitializeCriticalSection(&ctx->render_mu);
	InitializeConditionVariable(&ctx->render_cv);
#else
	if (pthread_mutex_init(&ctx->render_mu, NULL) != 0) {
		free(prefix);
		return Qnil;
	}
	if (pthread_cond_init(&ctx->render_cv, NULL) != 0) {
		pthread_mutex_destroy(&ctx->render_mu);
		free(prefix);
		return Qnil;
	}
#endif
	snprintf(ctx->async_prefix, sizeof ctx->async_prefix, "%s", prefix);
	free(prefix);
	ctx->async_stop = 0;
	ctx->async_dirty = atomic_exchange_explicit(&ctx->needs_render, 0, memory_order_acq_rel) ? 1 : 0;
	ctx->async_force = 0;
	ctx->async_w = width;
	ctx->async_h = height;
	ctx->async_write_slot = 0;
	ctx->async_ready_slot = -1;
	ctx->async_ready_seq = 0;
	ctx->async_taken_seq = 0;
	ctx->async_pinned_a = -1;
	ctx->async_pinned_b = -1;
	ctx->async_min_interval_ns = (max_fps > 0 && max_fps <= 120)
		? (1000000000LL / (int64_t) max_fps) : 0;
	ctx->async_last_render_ns = 0;
	atomic_store_explicit(&ctx->async_active, 1, memory_order_release);
#ifdef _WIN32
	ctx->render_thread = CreateThread(NULL, 0, etaf_mpv_render_worker_win32, ctx, 0, NULL);
	if (!ctx->render_thread) {
		atomic_store_explicit(&ctx->async_active, 0, memory_order_release);
		DeleteCriticalSection(&ctx->render_mu);
		return Qnil;
	}
#else
	if (pthread_create(&ctx->render_thread, NULL, etaf_mpv_render_worker, ctx) != 0) {
		atomic_store_explicit(&ctx->async_active, 0, memory_order_release);
		pthread_cond_destroy(&ctx->render_cv);
		pthread_mutex_destroy(&ctx->render_mu);
		return Qnil;
	}
#endif
	return etaf_intern(env, "t");
}

static emacs_value
f_async_resize (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !atomic_load_explicit(&ctx->async_active, memory_order_acquire))
		return Qnil;
	int width = (int) env->extract_integer(env, args[1]);
	int height = (int) env->extract_integer(env, args[2]);
	if (width <= 0 || height <= 0 || width > 8192 || height > 8192)
		return Qnil;
	etaf_mu_lock(ctx);
	ctx->async_w = width;
	ctx->async_h = height;
	ctx->async_force = 1;
	etaf_cv_signal(ctx);
	etaf_mu_unlock(ctx);
	return etaf_intern(env, "t");
}

static emacs_value
f_async_take (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !atomic_load_explicit(&ctx->async_active, memory_order_acquire))
		return Qnil;
	int slot = -1;
	uint64_t seq = 0;
	etaf_mu_lock(ctx);
	if (ctx->async_ready_slot >= 0 && ctx->async_ready_seq > ctx->async_taken_seq) {
		slot = ctx->async_ready_slot;
		seq = ctx->async_ready_seq;
		ctx->async_taken_seq = seq;
		if (slot != ctx->async_pinned_a) {
			ctx->async_pinned_b = ctx->async_pinned_a;
			ctx->async_pinned_a = slot;
		}
	}
	etaf_mu_unlock(ctx);
	if (slot < 0)
		return Qnil;
	char path[560];
	snprintf(path, sizeof path, "%s-%d.tif", ctx->async_prefix, slot);
	emacs_value Flist = etaf_intern(env, "list");
	emacs_value out[3] = {
		env->make_integer(env, (intmax_t) slot),
		etaf_make_str(env, path),
		env->make_integer(env, (intmax_t) seq)
	};
	return env->funcall(env, Flist, 3, out);
}

static emacs_value
f_render_canvas (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
#ifdef ETAF_EMACS_HAS_CANVAS
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !ctx->render)
		return etaf_intern(env, "nil");
	int width = (int) env->extract_integer(env, args[2]);
	int height = (int) env->extract_integer(env, args[3]);
	uint32_t *pixels = env->canvas_data(env, args[1]);
	if (!pixels || width <= 0 || height <= 0)
		return etaf_intern(env, "nil");
	size_t stride = 0;
	if (!etaf_mpv_render_sw(ctx, width, height, "bgr0", &stride))
		return etaf_intern(env, "nil");
	for (int y = 0; y < height; y++) {
		const uint32_t *src = (const uint32_t *) (ctx->sw_buf + (size_t) y * stride);
		uint32_t *dst = pixels + (size_t) y * (size_t) width;
		for (int x = 0; x < width; x++)
			dst[x] = src[x] | 0xFF000000u;
	}
	return etaf_intern(env, "t");
#else
	(void) args;
	return etaf_intern(env, "nil");
#endif
}

static emacs_value
f_render_raw (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !ctx->render)
		return Qnil;
	int width = (int) env->extract_integer(env, args[1]);
	int height = (int) env->extract_integer(env, args[2]);
	bool gray = env->eq(env, args[3], etaf_intern(env, "gray"));
	if (width <= 0 || height <= 0 || width > 2048 || height > 2048)
		return Qnil;

	size_t stride = 0;
	if (!etaf_mpv_render_sw(ctx, width, height, "rgb0", &stride))
		return Qnil;

	size_t total = (size_t) width * (size_t) height * (gray ? 1u : 3u);
	if (!etaf_mpv_ensure_out_buf(ctx, total))
		return Qnil;

	uint8_t *dst = ctx->out_buf;
	if (gray) {
		for (int y = 0; y < height; y++) {
			const uint8_t *src = ctx->sw_buf + (size_t) y * stride;
			for (int x = 0; x < width; x++) {
				*dst++ = (uint8_t) ((77u * src[0] + 150u * src[1] + 29u * src[2]) >> 8);
				src += 4;
			}
		}
	} else {
		for (int y = 0; y < height; y++) {
			const uint8_t *src = ctx->sw_buf + (size_t) y * stride;
			for (int x = 0; x < width; x++) {
				dst[0] = src[0];
				dst[1] = src[1];
				dst[2] = src[2];
				dst += 3;
				src += 4;
			}
		}
	}
	return env->make_unibyte_string(env, (const char *) ctx->out_buf,
	                                (ptrdiff_t) total);
}

static double
etaf_extract_num (emacs_env *env, emacs_value val)
{
	emacs_value type = env->type_of(env, val);
	if (env->eq(env, type, etaf_intern(env, "float")))
		return env->extract_float(env, val);
	if (env->eq(env, type, etaf_intern(env, "integer")))
		return (double) env->extract_integer(env, val);
	return 0.0;
}

static uint64_t
etaf_extract_window_id (emacs_env *env, emacs_value val)
{
	if (!env->is_not_nil(env, val))
		return 0;
	emacs_value type = env->type_of(env, val);
	if (env->eq(env, type, etaf_intern(env, "integer"))) {
		intmax_t n = env->extract_integer(env, val);
		return n > 0 ? (uint64_t) n : 0;
	}
	char *s = etaf_copy_lisp_string(env, val);
	if (!s)
		return 0;
	uint64_t wid = (uint64_t) strtoull(s, NULL, 0);
	free(s);
	return wid;
}

static emacs_value
f_gpu_configure (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) data;
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !ctx->gpu)
		return etaf_intern(env, "nil");
	char *title = env->is_not_nil(env, args[1]) ? etaf_copy_lisp_string(env, args[1]) : NULL;
	double outer_left = etaf_extract_num(env, args[2]);
	double outer_top  = etaf_extract_num(env, args[3]);
	double content_w  = etaf_extract_num(env, args[4]);
	double content_h  = etaf_extract_num(env, args[5]);
	bool is_child     = env->is_not_nil(env, args[6]);
	double x          = etaf_extract_num(env, args[7]);
	double y          = etaf_extract_num(env, args[8]);
	double w          = etaf_extract_num(env, args[9]);
	double h          = etaf_extract_num(env, args[10]);
	bool visible      = env->is_not_nil(env, args[11]);
	uint64_t wid      = (nargs >= 13) ? etaf_extract_window_id(env, args[12]) : 0;
	bool ok = etaf_mpv_gpu_configure(
		ctx->gpu, wid, title, outer_left, outer_top, content_w, content_h,
		is_child, x, y, w, h, visible);
	free(title);
	return etaf_intern(env, ok ? "t" : "nil");
}

static emacs_value
f_gpu_redraw (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !ctx->gpu)
		return etaf_intern(env, "nil");
	etaf_mpv_gpu_request_redraw(ctx->gpu);
	return etaf_intern(env, "t");
}

static emacs_value
f_gpu_frame_count (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !ctx->gpu)
		return env->make_integer(env, 0);
	return env->make_integer(env, (intmax_t) etaf_mpv_gpu_frame_count(ctx->gpu));
}

static emacs_value
f_gpu_snapshot_tiff_file (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) nargs; (void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	etaf_mpv_ctx *ctx = etaf_extract_ctx(env, args[0]);
	if (!ctx || !ctx->gpu)
		return Qnil;
	char *path = etaf_copy_lisp_string(env, args[1]);
	int width = (int) env->extract_integer(env, args[2]);
	int height = (int) env->extract_integer(env, args[3]);
	if (!path || width <= 0 || height <= 0 || width > 4096 || height > 4096) {
		free(path);
		return Qnil;
	}
	size_t stride = (size_t) width * 4u;
	size_t need = stride * (size_t) height;
	if (!etaf_mpv_ensure_sw_buf(ctx, need)) {
		free(path);
		return Qnil;
	}
	size_t total = 0;
	bool ok = etaf_mpv_gpu_grab_rgba(ctx->gpu, width, height, ctx->sw_buf)
		&& etaf_mpv_pack_rgb24_tiff(ctx, ctx->sw_buf, stride, width, height, &total)
		&& etaf_mpv_write_all_file(path, ctx->out_buf, total);
	free(path);
	return ok ? etaf_intern(env, "t") : Qnil;
}

int
emacs_module_init (struct emacs_runtime *runtime)
{
	emacs_env *env = runtime->get_environment(runtime);
	emacs_value defalias = etaf_intern(env, "defalias");
	struct {
		const char *name;
		ptrdiff_t min, max;
		emacs_value (*fn)(emacs_env *, ptrdiff_t, emacs_value *, void *);
	} fns[] = {
		{ "etaf-video-mpv--native-available-p", 0, 1, f_available_p },
		{ "etaf-video-mpv--native-version", 0, 0, f_version },
		{ "etaf-video-mpv--native-create", 0, 1, f_create },
		{ "etaf-video-mpv--native-gpu-available-p", 0, 0, f_gpu_available_p },
		{ "etaf-video-mpv--native-create-gpu", 0, 1, f_create_gpu },
		{ "etaf-video-mpv--native-gpu-configure", 12, 13, f_gpu_configure },
		{ "etaf-video-mpv--native-gpu-redraw", 1, 1, f_gpu_redraw },
		{ "etaf-video-mpv--native-gpu-frame-count", 1, 1, f_gpu_frame_count },
		{ "etaf-video-mpv--native-gpu-snapshot-tiff-file", 4, 4, f_gpu_snapshot_tiff_file },
		{ "etaf-video-mpv--native-destroy", 1, 1, f_destroy },
		{ "etaf-video-mpv--native-command", 2, 2, f_command },
		{ "etaf-video-mpv--native-set-property", 3, 3, f_set_property },
		{ "etaf-video-mpv--native-get-property", 2, 3, f_get_property },
		{ "etaf-video-mpv--native-poll-events", 1, 1, f_poll_events },
		{ "etaf-video-mpv--native-frame-ready-p", 1, 1, f_frame_ready_p },
		{ "etaf-video-mpv--native-render-ppm", 3, 3, f_render_ppm },
		{ "etaf-video-mpv--native-render-tiff", 3, 3, f_render_tiff },
		{ "etaf-video-mpv--native-render-tiff-file", 4, 4, f_render_tiff_file },
		{ "etaf-video-mpv--native-async-start", 4, 5, f_async_start },
		{ "etaf-video-mpv--native-async-resize", 3, 3, f_async_resize },
		{ "etaf-video-mpv--native-async-take", 1, 1, f_async_take },
		{ "etaf-video-mpv--native-render-canvas", 4, 4, f_render_canvas },
		{ "etaf-video-mpv--native-render-raw", 4, 4, f_render_raw },
	};
	for (size_t i = 0; i < sizeof fns / sizeof fns[0]; i++) {
		emacs_value fn = env->make_function(
			env, fns[i].min, fns[i].max, fns[i].fn, "", NULL);
		emacs_value a[2] = { etaf_intern(env, fns[i].name), fn };
		env->funcall(env, defalias, 2, a);
	}
	return 0;
}
