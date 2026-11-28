/* etaf-video-mpv-internal.h --- Internal declarations shared by etaf-video-mpv  -*- c-file-style: "linux" -*-

   Copyright (C) 2026  ETAF contributors

   This file is free software: you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by the
   Free Software Foundation, either version 3 of the License, or (at your
   option) any later version.  */

#ifndef ETAF_VIDEO_MPV_INTERNAL_H
#define ETAF_VIDEO_MPV_INTERNAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#  ifndef _WIN32_WINNT
#    define _WIN32_WINNT 0x0601
#  endif
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
   typedef HMODULE etaf_dl_t;
#else
   typedef void *etaf_dl_t;
#endif

typedef struct mpv_handle mpv_handle;
typedef struct mpv_render_context mpv_render_context;
typedef struct etaf_mpv_gpu etaf_mpv_gpu;

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
	ETAF_MPV_RP_OPENGL_INIT_PARAMS    = 2,
	ETAF_MPV_RP_OPENGL_FBO            = 3,
	ETAF_MPV_RP_FLIP_Y                = 4,
	ETAF_MPV_RP_ICC_PROFILE           = 6,
	ETAF_MPV_RP_BLOCK_FOR_TARGET_TIME = 12,
	ETAF_MPV_RP_SKIP_RENDERING        = 13,
	ETAF_MPV_RP_SW_SIZE               = 17,
	ETAF_MPV_RP_SW_FORMAT             = 18,
	ETAF_MPV_RP_SW_STRIDE             = 19,
	ETAF_MPV_RP_SW_POINTER            = 20,
} etaf_mpv_render_param_type;

typedef struct {
	etaf_mpv_render_param_type type;
	void *data;
} etaf_mpv_render_param;

typedef struct {
	void *(*get_proc_address)(void *ctx, const char *name);
	void *get_proc_address_ctx;
} etaf_mpv_opengl_init_params;

typedef struct {
	int fbo;
	int w;
	int h;
	int internal_format;
} etaf_mpv_opengl_fbo;

typedef void (*etaf_mpv_render_update_fn)(void *cb_ctx);

#define ETAF_MPV_RENDER_UPDATE_FRAME ((uint64_t) 1)

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

/* Platform native GPU surface hooks (implemented on macOS in
   etaf-video-mpv-macos.m, Windows in etaf-video-mpv-win32.c, Linux X11/Wayland
   in etaf-video-mpv-linux.c, and stubbed on other platforms).  */
bool etaf_mpv_gpu_platform_available (void);
etaf_mpv_gpu *etaf_mpv_gpu_create (mpv_handle *mpv, const etaf_mpv_api *api);
bool etaf_mpv_gpu_configure (etaf_mpv_gpu *gpu,
                             uint64_t window_id,
                             const char *title_hint,
                             double outer_left, double outer_top,
                             double content_w, double content_h,
                             bool is_child,
                             double x, double y, double w, double h,
                             bool visible);
void etaf_mpv_gpu_request_redraw (etaf_mpv_gpu *gpu);
uint64_t etaf_mpv_gpu_frame_count (etaf_mpv_gpu *gpu);
bool etaf_mpv_gpu_grab_rgba (etaf_mpv_gpu *gpu, int width, int height,
                             uint8_t *dst_rgba);
void etaf_mpv_gpu_destroy (etaf_mpv_gpu *gpu);

#endif /* ETAF_VIDEO_MPV_INTERNAL_H */
