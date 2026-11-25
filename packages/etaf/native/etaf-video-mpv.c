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

#include <emacs-module.h>

#include <locale.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#  include <malloc.h>
   typedef HMODULE etaf_dl_t;
#  define etaf_dl_open(path) LoadLibraryA(path)
#  define etaf_dl_sym(lib, name) ((void *) GetProcAddress((lib), (name)))
#  define etaf_dl_close(lib) FreeLibrary(lib)
#else
#  include <dlfcn.h>
   typedef void *etaf_dl_t;
#  define etaf_dl_open(path) dlopen((path), RTLD_LAZY | RTLD_LOCAL)
#  define etaf_dl_sym(lib, name) dlsym((lib), (name))
#  define etaf_dl_close(lib) dlclose(lib)
#endif

int plugin_is_GPL_compatible;

/* -------------------------------------------------------------------------
   Minimal stable libmpv v2 ABI declarations (from mpv/client.h & render.h)
   ------------------------------------------------------------------------- */

typedef struct mpv_handle mpv_handle;
typedef struct mpv_render_context mpv_render_context;

typedef enum {
	ETAF_MPV_FORMAT_NONE       = 0,
	ETAF_MPV_FORMAT_STRING     = 1,
	ETAF_MPV_FORMAT_OSD_STRING = 2,
	ETAF_MPV_FORMAT_FLAG       = 3,
	ETAF_MPV_FORMAT_INT64      = 4,
	ETAF_MPV_FORMAT_DOUBLE     = 5,
	ETAF_MPV_FORMAT_NODE       = 6,
	ETAF_MPV_FORMAT_NODE_ARRAY = 7,
	ETAF_MPV_FORMAT_NODE_MAP   = 8,
	ETAF_MPV_FORMAT_BYTE_ARRAY = 9,
} etaf_mpv_format;

typedef struct etaf_mpv_node_list etaf_mpv_node_list;

typedef struct {
	void *data;
	size_t size;
} etaf_mpv_byte_array;

typedef struct {
	union {
		char *string;
		int flag;
		int64_t int64;
		double double_;
		etaf_mpv_node_list *list;
		etaf_mpv_byte_array *ba;
	} u;
	etaf_mpv_format format;
} etaf_mpv_node;

struct etaf_mpv_node_list {
	int num;
	etaf_mpv_node *values;
	char **keys;
};

typedef enum {
	ETAF_MPV_EVENT_NONE             = 0,
	ETAF_MPV_EVENT_SHUTDOWN         = 1,
	ETAF_MPV_EVENT_START_FILE       = 6,
	ETAF_MPV_EVENT_END_FILE         = 7,
	ETAF_MPV_EVENT_FILE_LOADED      = 8,
	ETAF_MPV_EVENT_VIDEO_RECONFIG   = 17,
	ETAF_MPV_EVENT_SEEK             = 20,
	ETAF_MPV_EVENT_PLAYBACK_RESTART = 21,
} etaf_mpv_event_id;

typedef enum {
	ETAF_MPV_END_EOF      = 0,
	ETAF_MPV_END_STOP     = 2,
	ETAF_MPV_END_QUIT     = 3,
	ETAF_MPV_END_ERROR    = 4,
	ETAF_MPV_END_REDIRECT = 5,
} etaf_mpv_end_reason;

typedef struct {
	etaf_mpv_end_reason reason;
	int error;
	int64_t playlist_entry_id;
	int64_t playlist_insert_id;
	int playlist_insert_num_entries;
} etaf_mpv_event_end_file;

typedef struct {
	etaf_mpv_event_id event_id;
	int error;
	uint64_t reply_userdata;
	void *data;
} etaf_mpv_event;

typedef enum {
	ETAF_MPV_RP_INVALID               = 0,
	ETAF_MPV_RP_API_TYPE              = 1,
	ETAF_MPV_RP_BLOCK_FOR_TARGET_TIME = 12,
	ETAF_MPV_RP_SW_SIZE               = 17,
	ETAF_MPV_RP_SW_FORMAT             = 18,
	ETAF_MPV_RP_SW_STRIDE             = 19,
	ETAF_MPV_RP_SW_POINTER            = 20,
} etaf_mpv_render_param_type;

typedef struct {
	etaf_mpv_render_param_type type;
	void *data;
} etaf_mpv_render_param;

typedef void (*etaf_mpv_render_update_fn)(void *cb_ctx);

#define ETAF_MPV_RENDER_UPDATE_FRAME ((uint64_t) 1)

/* -------------------------------------------------------------------------
   Dynamically loaded libmpv function table
   ------------------------------------------------------------------------- */

typedef struct {
	etaf_dl_t lib;
	int loaded;
	unsigned long (*client_api_version)(void);
	const char *(*error_string)(int error);
	void (*free_fn)(void *data);
	void (*free_node_contents)(etaf_mpv_node *node);
	mpv_handle *(*create)(void);
	int (*initialize)(mpv_handle *ctx);
	void (*terminate_destroy)(mpv_handle *ctx);
	int (*set_option_string)(mpv_handle *ctx, const char *name, const char *data);
	int (*command)(mpv_handle *ctx, const char **args);
	int (*set_property)(mpv_handle *ctx, const char *name,
	                    etaf_mpv_format format, void *data);
	int (*set_property_string)(mpv_handle *ctx, const char *name, const char *data);
	int (*get_property)(mpv_handle *ctx, const char *name,
	                    etaf_mpv_format format, void *data);
	char *(*get_property_string)(mpv_handle *ctx, const char *name);
	etaf_mpv_event *(*wait_event)(mpv_handle *ctx, double timeout);
	int (*render_context_create)(mpv_render_context **res, mpv_handle *mpv,
	                             etaf_mpv_render_param *params);
	void (*render_context_set_update_callback)(mpv_render_context *ctx,
	                                           etaf_mpv_render_update_fn cb,
	                                           void *cb_ctx);
	uint64_t (*render_context_update)(mpv_render_context *ctx);
	int (*render_context_render)(mpv_render_context *ctx,
	                             etaf_mpv_render_param *params);
	void (*render_context_report_swap)(mpv_render_context *ctx);
	void (*render_context_free)(mpv_render_context *ctx);
} etaf_mpv_api;

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
	static const char *const candidates[] = {
		"libmpv-2.dll",
		"mpv-2.dll",
		"libmpv.dll",
		NULL
	};
#else
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

typedef struct {
	mpv_handle *mpv;
	mpv_render_context *render;
	atomic_int needs_render;
	int destroyed;
	uint8_t *sw_buf;
	size_t sw_cap;
	uint8_t *out_buf;
	size_t out_cap;
} etaf_mpv_ctx;

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
	if (ctx)
		atomic_store_explicit(&ctx->needs_render, 1, memory_order_release);
}

static void
etaf_mpv_teardown (etaf_mpv_ctx *ctx)
{
	if (!ctx || ctx->destroyed)
		return;
	ctx->destroyed = 1;
	if (ctx->render) {
		g_mpv.render_context_set_update_callback(ctx->render, NULL, NULL);
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

static emacs_value
f_create (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void) data;
	emacs_value Qnil = etaf_intern(env, "nil");
	if (!etaf_mpv_ensure_loaded(NULL))
		return Qnil;

	/* libmpv requires LC_NUMERIC="C" before mpv_initialize.  */
	setlocale(LC_NUMERIC, "C");

	mpv_handle *mpv = g_mpv.create();
	if (!mpv)
		return Qnil;

	/* Sensible, isolated defaults for embedded playback.  */
	g_mpv.set_option_string(mpv, "vo", "libmpv");
	g_mpv.set_option_string(mpv, "hwdec", "auto-copy");
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
		return Qnil;
	}

	etaf_mpv_ctx *ctx = calloc(1, sizeof *ctx);
	if (!ctx) {
		g_mpv.terminate_destroy(mpv);
		return Qnil;
	}
	ctx->mpv = mpv;
	atomic_init(&ctx->needs_render, 0);

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
		{ "etaf-video-mpv--native-destroy", 1, 1, f_destroy },
		{ "etaf-video-mpv--native-command", 2, 2, f_command },
		{ "etaf-video-mpv--native-set-property", 3, 3, f_set_property },
		{ "etaf-video-mpv--native-get-property", 2, 3, f_get_property },
		{ "etaf-video-mpv--native-poll-events", 1, 1, f_poll_events },
		{ "etaf-video-mpv--native-frame-ready-p", 1, 1, f_frame_ready_p },
		{ "etaf-video-mpv--native-render-ppm", 3, 3, f_render_ppm },
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
