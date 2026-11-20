/* etaf-video-canvas.c --- read video frames into an Emacs canvas buffer  -*- c-file-style: "linux" -*-

   The video session starts ffmpeg with its BGRA output redirected into a
   fifo.  This module drains that fifo straight into the canvas pixel buffer,
   so no frame-sized Emacs string or vector is allocated per frame.

   Public module functions:

     (etaf-video-canvas-open FILE)          open FILE, return fd or nil
     (etaf-video-canvas-read FD CANVAS N)   read up to N bytes into CANVAS
     (etaf-video-canvas-close FD)           close FD

   Copyright (C) 2026  ETAF contributors

   This file is free software: you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by the
   Free Software Foundation, either version 3 of the License, or (at your
   option) any later version.  */

#include <emacs-module.h>

#include <fcntl.h>
#include <stdint.h>
#include <unistd.h>

int plugin_is_GPL_compatible;

static emacs_value Qnil;

/* Open FILE and return its descriptor, or nil on failure.  Opening a fifo
   blocks until the producer opens the write end, which happens right after
   ffmpeg starts.  */

static emacs_value
canvas_open (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  char path[4096];
  ptrdiff_t size = sizeof path;
  if (!env->copy_string_contents (env, args[0], path, &size))
    return Qnil;
  int fd = open (path, O_RDONLY);
  return fd < 0 ? Qnil : env->make_integer (env, fd);
}

/* Read up to N bytes from FD into CANVAS's pixel buffer and return the
   number of bytes read.  Zero means the stream ended.  */

static emacs_value
canvas_read (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  int fd = (int) env->extract_integer (env, args[0]);
  int64_t want = env->extract_integer (env, args[2]);
  uint32_t *pixels = env->canvas_data (env, args[1]);
  if (!pixels)
    return env->make_integer (env, -2);
  int64_t got = 0;
  while (got < want)
    {
      ssize_t n = read (fd, (char *) pixels + got, (size_t) (want - got));
      if (n <= 0)
	break;
      got += n;
    }
  return env->make_integer (env, got);
}

static emacs_value
canvas_close (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  close ((int) env->extract_integer (env, args[0]));
  return env->intern (env, "t");
}

int
emacs_module_init (struct emacs_runtime *runtime)
{
  emacs_env *env = runtime->get_environment (runtime);
  Qnil = env->intern (env, "nil");
  emacs_value defalias = env->intern (env, "defalias");
  struct
  {
    const char *name;
    int min, max;
    emacs_value (*fn) (emacs_env *, ptrdiff_t, emacs_value *, void *);
  } functions[] = {
    { "etaf-video-canvas-open", 1, 1, canvas_open },
    { "etaf-video-canvas-read", 3, 3, canvas_read },
    { "etaf-video-canvas-close", 1, 1, canvas_close },
  };
  for (int i = 0; i < 3; i++)
    {
      emacs_value function = env->make_function (env, functions[i].min,
						 functions[i].max,
						 functions[i].fn, "", 0);
      env->funcall (env, defalias, 2,
		    (emacs_value[]){ env->intern (env, functions[i].name),
				     function });
    }
  return 0;
}
