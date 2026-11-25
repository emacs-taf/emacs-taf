/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Native QuickJS typesetting module for etaf-md (Mermaid via Pele + TeX math via MathJax).
 *
 * The dedicated background-thread QuickJS architecture, Emacs open_channel pipe
 * wakeup, memory/timeout sandbox, and CoreText/Pango label measurement are
 * directly inspired by LuciusChen/pele.el (https://github.com/LuciusChen/pele.el,
 * MIT License).
 */
#include <emacs-module.h>
#include <quickjs.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef ETAF_MD_USE_PANGO_DLOPEN
#include <dlfcn.h>
#endif
#ifdef ETAF_MD_USE_PANGO
#include <pango/pangocairo.h>
#endif
#ifdef ETAF_MD_USE_FONTCONFIG
#include <pango/pangofc-fontmap.h>
#endif
#ifdef ETAF_MD_USE_CORETEXT
#include <CoreText/CoreText.h>
#endif
#include "bundles.h"

#define EXPORT __attribute__((visibility("default")))
#define MEMORY_LIMIT (256u * 1024u * 1024u)
#define INPUT_LIMIT (1024u * 1024u)
#define OPTIONS_LIMIT (64u * 1024u)
#define MAX_PENDING 128

EXPORT int plugin_is_GPL_compatible;

typedef struct job {
    intmax_t id;
    char *kind;
    char *source;
    char *options;
    size_t kind_len;
    size_t source_len;
    size_t options_len;
    int timeout;
    atomic_bool cancelled;
    struct result *output;
    struct job *next;
} job;

typedef struct result {
    intmax_t id;
    char *json;
    struct result *next;
} result;

static struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    pthread_t thread;
    bool running;
    atomic_bool stopping;
    job *head;
    job *tail;
    job *active;
    result *done_head;
    result *done_tail;
    int pending;
    double deadline;
    bool timed_out;
    int notify_fd;
} engine = {
    .mutex = PTHREAD_MUTEX_INITIALIZER,
    .condition = PTHREAD_COND_INITIALIZER,
    .notify_fd = -1
};

static double milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1000.0 + now.tv_nsec / 1000000.0;
}

static char *failure(const char *code, const char *message) {
    size_t size = strlen(message) * 6 + strlen(code) + 80;
    char *json = malloc(size);
    if (!json) return NULL;
    size_t at = (size_t)snprintf(json, size, "{\"ok\":false,\"error\":{\"code\":\"%s\",\"message\":\"", code);
    for (const unsigned char *p = (const unsigned char *)message; *p; p++) {
        if (*p == '"' || *p == '\\') {
            json[at++] = '\\';
            json[at++] = (char)*p;
        } else if (*p < 32) {
            at += (size_t)snprintf(json + at, size - at, "\\u%04x", *p);
        } else {
            json[at++] = (char)*p;
        }
    }
    memcpy(json + at, "\"}}", 4);
    return json;
}

static char *exception_message(JSContext *context) {
    JSValue exception = JS_GetException(context);
    const char *text = JS_ToCString(context, exception);
    char *copy = strdup(text ? text : "JavaScript engine failed");
    if (text) JS_FreeCString(context, text);
    JS_FreeValue(context, exception);
    return copy;
}

static int interrupted(JSRuntime *runtime, void *opaque) {
    (void)runtime;
    (void)opaque;
    if (atomic_load(&engine.stopping)) return 1;
    if (engine.active && atomic_load(&engine.active->cancelled)) return 1;
    if (milliseconds() >= engine.deadline) {
        engine.timed_out = true;
        return 1;
    }
    return 0;
}

#ifdef ETAF_MD_USE_PANGO_DLOPEN
/* Runtime-loaded Pango/Cairo/Fontconfig ABI subset so one portable Linux .so
 * works across distributions without link-time soname coupling, falling back to
 * Pele's built-in estimator when Pango is absent on headless servers. */
enum {
    ETAF_PANGO_SCALE = 1024,
    ETAF_PANGO_WEIGHT_NORMAL = 400,
    ETAF_PANGO_WEIGHT_BOLD = 700,
    ETAF_PANGO_STYLE_NORMAL = 0,
    ETAF_PANGO_STYLE_ITALIC = 2,
    ETAF_CAIRO_HINT_METRICS_OFF = 1
};

typedef struct {
    int x;
    int y;
    int width;
    int height;
} etaf_pango_rect;

typedef struct {
    void *lib_pangocairo;
    void *lib_pango;
    void *lib_cairo;
    void *lib_gobject;
    void *lib_fontconfig;
    void *lib_pangoft2;
    void *(*pango_cairo_font_map_new)(void);
    void *(*pango_font_map_create_context)(void *);
    void (*pango_cairo_context_set_resolution)(void *, double);
    void (*pango_cairo_context_set_font_options)(void *, const void *);
    void (*pango_context_set_round_glyph_positions)(void *, int);
    void *(*pango_layout_new)(void *);
    void *(*pango_font_description_new)(void);
    void (*pango_font_description_set_family)(void *, const char *);
    void (*pango_font_description_set_absolute_size)(void *, double);
    void (*pango_font_description_set_weight)(void *, int);
    void (*pango_font_description_set_style)(void *, int);
    void (*pango_font_description_free)(void *);
    void (*pango_layout_set_font_description)(void *, const void *);
    void (*pango_layout_set_text)(void *, const char *, int);
    void (*pango_layout_get_extents)(void *, etaf_pango_rect *, etaf_pango_rect *);
    void *(*cairo_font_options_create)(void);
    void (*cairo_font_options_set_hint_metrics)(void *, int);
    void (*cairo_font_options_destroy)(void *);
    void (*g_object_unref)(void *);
    unsigned char *(*fc_config_filename)(const unsigned char *);
    void (*fc_str_free)(unsigned char *);
    void *(*fc_config_create)(void);
    int (*fc_config_parse_memory)(void *, const unsigned char *, int);
    int (*fc_config_build_fonts)(void *);
    void (*fc_config_destroy)(void *);
    void (*pango_fc_font_map_set_config)(void *, void *);
    void *fonts;
    void *context;
    void *layout;
    bool ready;
} text_engine;

static atomic_bool pango_dlopen_active = false;

static void close_pango_dlopen(text_engine *text) {
    if (text->layout && text->g_object_unref) text->g_object_unref(text->layout);
    if (text->context && text->g_object_unref) text->g_object_unref(text->context);
    if (text->fonts && text->g_object_unref) text->g_object_unref(text->fonts);
    text->layout = NULL;
    text->context = NULL;
    text->fonts = NULL;
    if (text->lib_pangoft2) dlclose(text->lib_pangoft2);
    if (text->lib_fontconfig) dlclose(text->lib_fontconfig);
    if (text->lib_pangocairo) dlclose(text->lib_pangocairo);
    if (text->lib_pango) dlclose(text->lib_pango);
    if (text->lib_cairo) dlclose(text->lib_cairo);
    if (text->lib_gobject) dlclose(text->lib_gobject);
    memset(text, 0, sizeof(*text));
}

static bool init_pango_dlopen(text_engine *text) {
    memset(text, 0, sizeof(*text));
    text->lib_pangocairo = dlopen("libpangocairo-1.0.so.0", RTLD_LAZY | RTLD_LOCAL);
    text->lib_pango = dlopen("libpango-1.0.so.0", RTLD_LAZY | RTLD_LOCAL);
    text->lib_cairo = dlopen("libcairo.so.2", RTLD_LAZY | RTLD_LOCAL);
    text->lib_gobject = dlopen("libgobject-2.0.so.0", RTLD_LAZY | RTLD_LOCAL);
    if (!text->lib_pangocairo || !text->lib_pango || !text->lib_cairo || !text->lib_gobject) {
        close_pango_dlopen(text);
        return false;
    }
#define LOAD_SYM(handle, field, sym)                                      \
    do {                                                                  \
        *(void **)(&text->field) = dlsym(handle, sym);                    \
        if (!text->field) { close_pango_dlopen(text); return false; }     \
    } while (0)
    LOAD_SYM(text->lib_pangocairo, pango_cairo_font_map_new, "pango_cairo_font_map_new");
    LOAD_SYM(text->lib_pangocairo, pango_cairo_context_set_resolution, "pango_cairo_context_set_resolution");
    LOAD_SYM(text->lib_pangocairo, pango_cairo_context_set_font_options, "pango_cairo_context_set_font_options");
    LOAD_SYM(text->lib_pango, pango_font_map_create_context, "pango_font_map_create_context");
    LOAD_SYM(text->lib_pango, pango_context_set_round_glyph_positions, "pango_context_set_round_glyph_positions");
    LOAD_SYM(text->lib_pango, pango_layout_new, "pango_layout_new");
    LOAD_SYM(text->lib_pango, pango_font_description_new, "pango_font_description_new");
    LOAD_SYM(text->lib_pango, pango_font_description_set_family, "pango_font_description_set_family");
    LOAD_SYM(text->lib_pango, pango_font_description_set_absolute_size, "pango_font_description_set_absolute_size");
    LOAD_SYM(text->lib_pango, pango_font_description_set_weight, "pango_font_description_set_weight");
    LOAD_SYM(text->lib_pango, pango_font_description_set_style, "pango_font_description_set_style");
    LOAD_SYM(text->lib_pango, pango_font_description_free, "pango_font_description_free");
    LOAD_SYM(text->lib_pango, pango_layout_set_font_description, "pango_layout_set_font_description");
    LOAD_SYM(text->lib_pango, pango_layout_set_text, "pango_layout_set_text");
    LOAD_SYM(text->lib_pango, pango_layout_get_extents, "pango_layout_get_extents");
    LOAD_SYM(text->lib_cairo, cairo_font_options_create, "cairo_font_options_create");
    LOAD_SYM(text->lib_cairo, cairo_font_options_set_hint_metrics, "cairo_font_options_set_hint_metrics");
    LOAD_SYM(text->lib_cairo, cairo_font_options_destroy, "cairo_font_options_destroy");
    LOAD_SYM(text->lib_gobject, g_object_unref, "g_object_unref");
#undef LOAD_SYM

    text->fonts = text->pango_cairo_font_map_new();
    if (!text->fonts) {
        close_pango_dlopen(text);
        return false;
    }
    /* Optional fontconfig fallback when system fonts.conf is missing. */
    text->lib_fontconfig = dlopen("libfontconfig.so.1", RTLD_LAZY | RTLD_LOCAL);
    text->lib_pangoft2 = dlopen("libpangoft2-1.0.so.0", RTLD_LAZY | RTLD_LOCAL);
    if (text->lib_fontconfig && text->lib_pangoft2) {
        *(void **)(&text->fc_config_filename) = dlsym(text->lib_fontconfig, "FcConfigFilename");
        *(void **)(&text->fc_str_free) = dlsym(text->lib_fontconfig, "FcStrFree");
        *(void **)(&text->fc_config_create) = dlsym(text->lib_fontconfig, "FcConfigCreate");
        *(void **)(&text->fc_config_parse_memory) = dlsym(text->lib_fontconfig, "FcConfigParseAndLoadFromMemory");
        *(void **)(&text->fc_config_build_fonts) = dlsym(text->lib_fontconfig, "FcConfigBuildFonts");
        *(void **)(&text->fc_config_destroy) = dlsym(text->lib_fontconfig, "FcConfigDestroy");
        *(void **)(&text->pango_fc_font_map_set_config) = dlsym(text->lib_pangoft2, "pango_fc_font_map_set_config");
        if (text->fc_config_filename && text->fc_str_free && text->fc_config_create
            && text->fc_config_parse_memory && text->fc_config_build_fonts
            && text->fc_config_destroy && text->pango_fc_font_map_set_config) {
            unsigned char *filename = text->fc_config_filename(NULL);
            bool readable = false;
            if (filename) {
                readable = access((const char *)filename, R_OK) == 0;
                text->fc_str_free(filename);
            }
            if (!readable) {
                const unsigned char fallback[] =
                    "<fontconfig><dir>/usr/share/fonts</dir><dir>/usr/local/share/fonts</dir>"
                    "<dir prefix=\"xdg\">fonts</dir><dir>~/.fonts</dir>"
                    "<cachedir prefix=\"xdg\">fontconfig</cachedir>"
                    "<include ignore_missing=\"yes\" prefix=\"xdg\">fontconfig/fonts.conf</include>"
                    "<include ignore_missing=\"yes\" prefix=\"xdg\">fontconfig/conf.d</include>"
                    "<alias><family>sans-serif</family><prefer><family>DejaVu Sans</family></prefer></alias>"
                    "<alias><family>serif</family><prefer><family>DejaVu Serif</family></prefer></alias>"
                    "<alias><family>monospace</family><prefer><family>DejaVu Sans Mono</family></prefer></alias>"
                    "</fontconfig>";
                void *config = text->fc_config_create();
                if (config) {
                    if (text->fc_config_parse_memory(config, fallback, 1)
                        && text->fc_config_build_fonts(config)) {
                        text->pango_fc_font_map_set_config(text->fonts, config);
                    }
                    text->fc_config_destroy(config);
                }
            }
        }
    }
    text->context = text->pango_font_map_create_context(text->fonts);
    if (!text->context) {
        close_pango_dlopen(text);
        return false;
    }
    text->pango_cairo_context_set_resolution(text->context, 96.0);
    void *font_options = text->cairo_font_options_create();
    if (font_options) {
        text->cairo_font_options_set_hint_metrics(font_options, ETAF_CAIRO_HINT_METRICS_OFF);
        text->pango_cairo_context_set_font_options(text->context, font_options);
        text->cairo_font_options_destroy(font_options);
    }
    text->pango_context_set_round_glyph_positions(text->context, 0);
    text->layout = text->pango_layout_new(text->context);
    if (!text->layout) {
        close_pango_dlopen(text);
        return false;
    }
    text->ready = true;
    atomic_store(&pango_dlopen_active, true);
    return true;
}
#endif

#ifdef ETAF_MD_USE_PANGO
typedef struct {
    PangoFontMap *fonts;
    PangoContext *context;
    PangoLayout *layout;
} text_engine;

#ifdef ETAF_MD_USE_FONTCONFIG
static void configure_fonts(PangoFontMap *fonts) {
    FcChar8 *filename = FcConfigFilename(NULL);
    if (filename) {
        bool readable = access((const char *)filename, R_OK) == 0;
        FcStrFree(filename);
        if (readable) return;
    }
    const FcChar8 fallback[] =
        "<fontconfig><dir>/usr/share/fonts</dir><dir>/usr/local/share/fonts</dir>"
        "<dir prefix=\"xdg\">fonts</dir><dir>~/.fonts</dir>"
        "<cachedir prefix=\"xdg\">fontconfig</cachedir>"
        "<include ignore_missing=\"yes\" prefix=\"xdg\">fontconfig/fonts.conf</include>"
        "<include ignore_missing=\"yes\" prefix=\"xdg\">fontconfig/conf.d</include>"
        "<alias><family>sans-serif</family><prefer><family>DejaVu Sans</family></prefer></alias>"
        "<alias><family>serif</family><prefer><family>DejaVu Serif</family></prefer></alias>"
        "<alias><family>monospace</family><prefer><family>DejaVu Sans Mono</family></prefer></alias>"
        "</fontconfig>";
    FcConfig *config = FcConfigCreate();
    if (config) {
        if (FcConfigParseAndLoadFromMemory(config, fallback, FcTrue) && FcConfigBuildFonts(config)) {
            pango_fc_font_map_set_config(PANGO_FC_FONT_MAP(fonts), config);
        }
        FcConfigDestroy(config);
    }
}
#endif
#endif

#ifdef ETAF_MD_USE_CORETEXT
/* Preserve CSS font-family order for both the primary face and CJK fallbacks. */
static CTFontRef find_font(const char *family, double size, int32_t style) {
    CFStringRef names = CFStringCreateWithCString(NULL, family, kCFStringEncodingUTF8);
    if (!names) return NULL;
    CFArrayRef families = CFStringCreateArrayBySeparatingStrings(NULL, names, CFSTR(","));
    CFRelease(names);
    const void *key = kCTFontFamilyNameAttribute;
    CFSetRef mandatory = CFSetCreate(NULL, &key, 1, &kCFTypeSetCallBacks);
    CFMutableArrayRef cascade = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CTFontSymbolicTraits traits =
        (style & 1 ? kCTFontBoldTrait : 0) | (style & 2 ? kCTFontItalicTrait : 0);
    CFNumberRef trait_number = CFNumberCreate(NULL, kCFNumberSInt32Type, &traits);
    const void *trait_key = kCTFontSymbolicTrait;
    const void *trait_value = trait_number;
    CFDictionaryRef font_traits = CFDictionaryCreate(
        NULL, &trait_key, &trait_value, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontRef font = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(families); i++) {
        CFMutableStringRef name =
            CFStringCreateMutableCopy(NULL, 0, CFArrayGetValueAtIndex(families, i));
        CFStringTrimWhitespace(name);
        CFStringRef resolved = name;
        if (CFStringCompare(name, CFSTR("sans-serif"), kCFCompareCaseInsensitive) == 0) {
            resolved = CFSTR("Helvetica");
        } else if (CFStringCompare(name, CFSTR("serif"), kCFCompareCaseInsensitive) == 0) {
            resolved = CFSTR("Times");
        } else if (CFStringCompare(name, CFSTR("monospace"), kCFCompareCaseInsensitive) == 0) {
            resolved = CFSTR("Menlo");
        }
        const void *keys[] = {kCTFontFamilyNameAttribute, kCTFontTraitsAttribute};
        const void *values[] = {resolved, font_traits};
        CFDictionaryRef attributes = CFDictionaryCreate(
            NULL, keys, values, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTFontDescriptorRef request = CTFontDescriptorCreateWithAttributes(attributes);
        CTFontDescriptorRef match = CTFontDescriptorCreateMatchingFontDescriptor(request, mandatory);
        if (match) {
            if (!font) font = CTFontCreateWithFontDescriptor(match, size, NULL);
            CFArrayAppendValue(cascade, match);
            CFRelease(match);
        }
        CFRelease(request);
        CFRelease(attributes);
        CFRelease(name);
    }
    CFRelease(mandatory);
    CFRelease(families);
    CFRelease(font_traits);
    CFRelease(trait_number);
    if (!font) font = CTFontCreateWithName(CFSTR("Helvetica"), size, NULL);
    if (font && traits) {
        CTFontRef variant = CTFontCreateCopyWithSymbolicTraits(font, size, NULL, traits, traits);
        if (variant) {
            CFRelease(font);
            font = variant;
        }
    }
    if (font && CFArrayGetCount(cascade)) {
        const void *cascade_key = kCTFontCascadeListAttribute;
        const void *value = cascade;
        CFDictionaryRef attributes = CFDictionaryCreate(
            NULL, &cascade_key, &value, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
        CTFontRef combined = CTFontCreateCopyWithAttributes(font, size, NULL, descriptor);
        if (combined) {
            CFRelease(font);
            font = combined;
        }
        CFRelease(descriptor);
        CFRelease(attributes);
    }
    CFRelease(cascade);
    return font;
}
#endif

#if defined(ETAF_MD_USE_PANGO) || defined(ETAF_MD_USE_PANGO_DLOPEN) || defined(ETAF_MD_USE_CORETEXT)
static JSValue measure_text(JSContext *context, JSValueConst this_value,
                            int argc, JSValueConst *args) {
    (void)this_value;
    if (argc != 4) {
        return JS_ThrowTypeError(context, "Expected text, size, style and font family");
    }
    double size;
    int32_t style;
    if (JS_ToFloat64(context, &size, args[1]) || JS_ToInt32(context, &style, args[2])) {
        return JS_EXCEPTION;
    }
    if (!(size > 0 && size <= 4000)) {
        return JS_ThrowRangeError(context, "Invalid text size");
    }
    size_t length;
    const char *label = JS_ToCStringLen(context, &length, args[0]);
    if (!label) return JS_EXCEPTION;
    const char *family = JS_ToCString(context, args[3]);
    if (!family) {
        JS_FreeCString(context, label);
        return JS_EXCEPTION;
    }
#ifdef ETAF_MD_USE_PANGO_DLOPEN
    text_engine *text = JS_GetContextOpaque(context);
    void *font = text->pango_font_description_new();
    text->pango_font_description_set_family(font, family);
    text->pango_font_description_set_absolute_size(font, size * ETAF_PANGO_SCALE);
    text->pango_font_description_set_weight(
        font, style & 1 ? ETAF_PANGO_WEIGHT_BOLD : ETAF_PANGO_WEIGHT_NORMAL);
    text->pango_font_description_set_style(
        font, style & 2 ? ETAF_PANGO_STYLE_ITALIC : ETAF_PANGO_STYLE_NORMAL);
    text->pango_layout_set_font_description(text->layout, font);
    text->pango_layout_set_text(text->layout, label, (int)length);
    etaf_pango_rect logical = {0, 0, 0, 0};
    text->pango_layout_get_extents(text->layout, NULL, &logical);
    text->pango_font_description_free(font);
    double width = (double)logical.width / ETAF_PANGO_SCALE;
#elif defined(ETAF_MD_USE_PANGO)
    text_engine *text = JS_GetContextOpaque(context);
    PangoFontDescription *font = pango_font_description_new();
    pango_font_description_set_family(font, family);
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    pango_font_description_set_weight(font, style & 1 ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
    pango_font_description_set_style(font, style & 2 ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
    pango_layout_set_font_description(text->layout, font);
    pango_layout_set_text(text->layout, label, (int)length);
    PangoRectangle logical;
    pango_layout_get_extents(text->layout, NULL, &logical);
    pango_font_description_free(font);
    double width = (double)logical.width / PANGO_SCALE;
#else
    CFStringRef string = CFStringCreateWithBytes(
        NULL, (const UInt8 *)label, (CFIndex)length, kCFStringEncodingUTF8, false);
    CTFontRef font = find_font(family, size, style);
    double width = -1;
    if (string && font) {
        const void *key = kCTFontAttributeName;
        const void *value = font;
        CFDictionaryRef attributes = CFDictionaryCreate(
            NULL, &key, &value, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, string, attributes);
        CTLineRef line = CTLineCreateWithAttributedString(attributed);
        width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        CFRelease(line);
        CFRelease(attributed);
        CFRelease(attributes);
    }
    if (font) CFRelease(font);
    if (string) CFRelease(string);
#endif
    JS_FreeCString(context, family);
    JS_FreeCString(context, label);
    return width < 0
        ? JS_ThrowInternalError(context, "Could not measure label")
        : JS_NewFloat64(context, width);
}
#endif

static void free_job(job *item) {
    free(item->kind);
    free(item->source);
    free(item->options);
    free(item->output);
    free(item);
}

static void complete(job *item, char *json) {
    result *output = item->output;
    item->output = NULL;
    output->id = item->id;
    output->json = json ? json : failure("memory", "Not enough memory for the render result");
    output->next = NULL;
    pthread_mutex_lock(&engine.mutex);
    engine.active = NULL;
    if (engine.done_tail) engine.done_tail->next = output;
    else engine.done_head = output;
    engine.done_tail = output;
    if (engine.notify_fd >= 0) {
        ssize_t written = write(engine.notify_fd, ".", 1);
        (void)written;
    }
    pthread_mutex_unlock(&engine.mutex);
    free_job(item);
}

static void *worker(void *unused) {
    (void)unused;
    sigset_t signals;
    sigemptyset(&signals);
    sigaddset(&signals, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &signals, NULL);

    JSRuntime *runtime = JS_NewRuntime();
    JSContext *context = NULL;
#if defined(ETAF_MD_USE_PANGO) || defined(ETAF_MD_USE_PANGO_DLOPEN)
    text_engine text = {0};
#endif
    JSValue render = JS_UNDEFINED;
    char *initialization_error = NULL;
    bool mathjax_loaded = false;
    char *mathjax_error = NULL;

    engine.deadline = milliseconds() + 15000;
    if (runtime) {
        JS_SetMemoryLimit(runtime, MEMORY_LIMIT);
        JS_SetMaxStackSize(runtime, 4u * 1024u * 1024u);
        JS_SetInterruptHandler(runtime, interrupted, NULL);
        context = JS_NewContext(runtime);
    }
    if (!context) {
        initialization_error = strdup("Could not create the JavaScript runtime");
    } else {
#ifdef ETAF_MD_USE_PANGO_DLOPEN
        if (init_pango_dlopen(&text)) {
            JS_SetContextOpaque(context, &text);
            JSValue global = JS_GetGlobalObject(context);
            JS_SetPropertyStr(
                context, global, "__etafMdMeasureText",
                JS_NewCFunction(context, measure_text, "__etafMdMeasureText", 4));
            JS_FreeValue(context, global);
        }
#elif defined(ETAF_MD_USE_PANGO)
        text.fonts = pango_cairo_font_map_new();
#ifdef ETAF_MD_USE_FONTCONFIG
        configure_fonts(text.fonts);
#endif
        text.context = pango_font_map_create_context(text.fonts);
        pango_cairo_context_set_resolution(text.context, 96.0);
        cairo_font_options_t *font_options = cairo_font_options_create();
        cairo_font_options_set_hint_metrics(font_options, CAIRO_HINT_METRICS_OFF);
        pango_cairo_context_set_font_options(text.context, font_options);
        cairo_font_options_destroy(font_options);
        pango_context_set_round_glyph_positions(text.context, false);
        text.layout = pango_layout_new(text.context);
        JS_SetContextOpaque(context, &text);
#endif
#if defined(ETAF_MD_USE_PANGO) || defined(ETAF_MD_USE_CORETEXT)
        JSValue global = JS_GetGlobalObject(context);
        JS_SetPropertyStr(
            context, global, "__etafMdMeasureText",
            JS_NewCFunction(context, measure_text, "__etafMdMeasureText", 4));
        JS_FreeValue(context, global);
#endif
        JSValue value = JS_Eval(
            context, (const char *)etaf_md_pele_bundle, etaf_md_pele_bundle_len,
            "pele.global.js", JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(value)) initialization_error = exception_message(context);
        JS_FreeValue(context, value);

        if (!initialization_error) {
            value = JS_Eval(
                context, (const char *)etaf_md_bridge_bundle, etaf_md_bridge_bundle_len,
                "bridge.js", JS_EVAL_TYPE_GLOBAL);
            if (JS_IsException(value)) initialization_error = exception_message(context);
            JS_FreeValue(context, value);
        }
        if (!initialization_error) {
            JSValue global = JS_GetGlobalObject(context);
            render = JS_GetPropertyStr(context, global, "__etafMdRender");
            JS_FreeValue(context, global);
            if (!JS_IsFunction(context, render)) {
                initialization_error = strdup("etaf-md render entry point is missing");
            }
        }
    }

    for (;;) {
        pthread_mutex_lock(&engine.mutex);
        while (!engine.head && !atomic_load(&engine.stopping)) {
            pthread_cond_wait(&engine.condition, &engine.mutex);
        }
        if (atomic_load(&engine.stopping)) {
            pthread_mutex_unlock(&engine.mutex);
            break;
        }
        job *item = engine.head;
        engine.head = item->next;
        if (!engine.head) engine.tail = NULL;
        engine.active = item;
        pthread_mutex_unlock(&engine.mutex);

        char *json = NULL;
        if (atomic_load(&item->cancelled)) {
            json = failure("cancelled", "Rendering was cancelled");
        } else if (initialization_error) {
            json = failure("engine", initialization_error);
        } else {
            /* Lazily initialize MathJax only when the first math job arrives so
             * diagram-only documents pay zero startup cost for TeX tables. */
            if (strcmp(item->kind, "math") == 0 && !mathjax_loaded && !mathjax_error) {
                engine.timed_out = false;
                engine.deadline = milliseconds() + 15000;
                JSValue mj = JS_Eval(
                    context, (const char *)etaf_md_mathjax_bundle, etaf_md_mathjax_bundle_len,
                    "mathjax-tex-svg.global.js", JS_EVAL_TYPE_GLOBAL);
                if (JS_IsException(mj)) mathjax_error = exception_message(context);
                else mathjax_loaded = true;
                JS_FreeValue(context, mj);
            }
            if (strcmp(item->kind, "math") == 0 && mathjax_error) {
                json = failure("engine", mathjax_error);
            } else {
                engine.timed_out = false;
                engine.deadline = milliseconds() + item->timeout;
                JSValue args[] = {
                    JS_NewStringLen(context, item->kind, item->kind_len),
                    JS_NewStringLen(context, item->source, item->source_len),
                    JS_NewStringLen(context, item->options, item->options_len)
                };
                JSValue value =
                    (JS_IsException(args[0]) || JS_IsException(args[1]) || JS_IsException(args[2]))
                    ? JS_EXCEPTION
                    : JS_Call(context, render, JS_UNDEFINED, 3, args);
                JS_FreeValue(context, args[0]);
                JS_FreeValue(context, args[1]);
                JS_FreeValue(context, args[2]);
                if (JS_IsException(value)) {
                    char *message = exception_message(context);
                    const char *code = atomic_load(&item->cancelled)
                        ? "cancelled"
                        : (engine.timed_out ? "timeout" : "engine");
                    const char *text = atomic_load(&item->cancelled)
                        ? "Rendering was cancelled"
                        : (engine.timed_out
                           ? "Rendering exceeded its time limit"
                           : (message ? message : "JavaScript engine failed"));
                    json = failure(code, text);
                    free(message);
                } else {
                    const char *text = JS_ToCString(context, value);
                    if (text) {
                        json = strdup(text);
                        JS_FreeCString(context, text);
                    } else {
                        char *message = exception_message(context);
                        json = failure("engine", message ? message : "Could not read the result");
                        free(message);
                    }
                }
                JS_FreeValue(context, value);
                engine.deadline = milliseconds() + 10000;
                JS_RunGC(runtime);
            }
        }
        complete(item, json);
    }

    if (context) {
        JS_FreeValue(context, render);
        JS_FreeContext(context);
    }
#ifdef ETAF_MD_USE_PANGO_DLOPEN
    close_pango_dlopen(&text);
#elif defined(ETAF_MD_USE_PANGO)
    if (text.layout) g_object_unref(text.layout);
    if (text.context) g_object_unref(text.context);
    if (text.fonts) g_object_unref(text.fonts);
#endif
    if (runtime) JS_FreeRuntime(runtime);
    free(initialization_error);
    free(mathjax_error);
    return NULL;
}

static bool pending_exit(emacs_env *env) {
    return env->non_local_exit_check(env) != emacs_funcall_exit_return;
}

static emacs_value signal_error(emacs_env *env, const char *message) {
    emacs_value text = env->make_string(env, message, (ptrdiff_t)strlen(message));
    emacs_value data = env->funcall(env, env->intern(env, "list"), 1, &text);
    env->non_local_exit_signal(env, env->intern(env, "error"), data);
    return env->intern(env, "nil");
}

static char *copy_string(emacs_env *env, emacs_value value, size_t limit, size_t *length) {
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, value, NULL, &size)) return NULL;
    if (size < 1 || (size_t)size > limit + 1) {
        signal_error(env, "etaf-md typeset input exceeds its size limit");
        return NULL;
    }
    char *text = malloc((size_t)size);
    if (!text) {
        signal_error(env, "Not enough memory for the typeset request");
        return NULL;
    }
    if (!env->copy_string_contents(env, value, text, &size)) {
        free(text);
        return NULL;
    }
    *length = (size_t)size - 1;
    return text;
}

static int start_worker(void) {
    if (engine.running) return 0;
    atomic_store(&engine.stopping, false);
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 8u * 1024u * 1024u);
    int error = pthread_create(&engine.thread, &attributes, worker, NULL);
    pthread_attr_destroy(&attributes);
    if (!error) engine.running = true;
    return error;
}

static emacs_value submit(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) {
    (void)nargs;
    (void)data;
    intmax_t id = env->extract_integer(env, args[0]);
    if (pending_exit(env)) return env->intern(env, "nil");
    intmax_t timeout = env->extract_integer(env, args[4]);
    if (pending_exit(env)) return env->intern(env, "nil");
    if (id < 1 || timeout < 1 || timeout > 60000) {
        return signal_error(env, "Invalid etaf-md typeset request id or timeout");
    }

    job *item = calloc(1, sizeof(*item));
    if (!item) return signal_error(env, "Not enough memory for the typeset request");
    item->output = calloc(1, sizeof(*item->output));
    if (!item->output) {
        free_job(item);
        return signal_error(env, "Not enough memory for the typeset result");
    }
    item->id = id;
    item->timeout = (int)timeout;
    atomic_init(&item->cancelled, false);
    item->kind = copy_string(env, args[1], 32, &item->kind_len);
    if (item->kind) item->source = copy_string(env, args[2], INPUT_LIMIT, &item->source_len);
    if (item->source) item->options = copy_string(env, args[3], OPTIONS_LIMIT, &item->options_len);
    if (!item->kind || !item->source || !item->options) {
        free_job(item);
        return env->intern(env, "nil");
    }
    if (start_worker()) {
        free_job(item);
        return signal_error(env, "Could not start the etaf-md typeset worker thread");
    }

    pthread_mutex_lock(&engine.mutex);
    if (engine.pending >= MAX_PENDING) {
        pthread_mutex_unlock(&engine.mutex);
        free_job(item);
        return signal_error(env, "etaf-md typeset request queue is full");
    }
    engine.pending++;
    if (engine.tail) engine.tail->next = item;
    else engine.head = item;
    engine.tail = item;
    pthread_cond_signal(&engine.condition);
    pthread_mutex_unlock(&engine.mutex);
    return env->intern(env, "t");
}

static emacs_value poll_result(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) {
    (void)nargs;
    (void)args;
    (void)data;
    pthread_mutex_lock(&engine.mutex);
    result *item = engine.done_head;
    if (item) {
        engine.done_head = item->next;
        if (!engine.done_head) engine.done_tail = NULL;
        engine.pending--;
    }
    pthread_mutex_unlock(&engine.mutex);
    if (!item) return env->intern(env, "nil");
    const char *json = item->json
        ? item->json
        : "{\"ok\":false,\"error\":{\"code\":\"memory\",\"message\":\"Not enough memory\"}}";
    emacs_value values[] = {
        env->make_integer(env, item->id),
        env->make_string(env, json, (ptrdiff_t)strlen(json))
    };
    free(item->json);
    free(item);
    return env->funcall(env, env->intern(env, "list"), 2, values);
}

static emacs_value cancel(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) {
    (void)nargs;
    (void)data;
    intmax_t id = env->extract_integer(env, args[0]);
    if (pending_exit(env)) return env->intern(env, "nil");
    pthread_mutex_lock(&engine.mutex);
    if (engine.active && engine.active->id == id) {
        atomic_store(&engine.active->cancelled, true);
    }
    for (job *item = engine.head; item; item = item->next) {
        if (item->id == id) atomic_store(&item->cancelled, true);
    }
    pthread_mutex_unlock(&engine.mutex);
    return env->intern(env, "nil");
}

static emacs_value set_channel(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) {
    (void)nargs;
    (void)data;
    int fd = env->open_channel(env, args[0]);
    if (pending_exit(env)) return env->intern(env, "nil");
    if (fd < 0) return signal_error(env, "Could not open the etaf-md completion channel");
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd);
        return signal_error(env, "Could not configure the etaf-md completion channel");
    }
    pthread_mutex_lock(&engine.mutex);
    if (engine.notify_fd >= 0) close(engine.notify_fd);
    engine.notify_fd = fd;
    pthread_mutex_unlock(&engine.mutex);
    return env->intern(env, "t");
}

static void stop_worker(void) {
    if (!engine.running) return;
    atomic_store(&engine.stopping, true);
    pthread_mutex_lock(&engine.mutex);
    pthread_cond_signal(&engine.condition);
    pthread_mutex_unlock(&engine.mutex);
    pthread_join(engine.thread, NULL);
    while (engine.head) {
        job *next = engine.head->next;
        free_job(engine.head);
        engine.head = next;
    }
    while (engine.done_head) {
        result *next = engine.done_head->next;
        free(engine.done_head->json);
        free(engine.done_head);
        engine.done_head = next;
    }
    engine.tail = NULL;
    engine.done_tail = NULL;
    engine.active = NULL;
    engine.pending = 0;
    engine.running = false;
}

static emacs_value shutdown_engine(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) {
    (void)nargs;
    (void)args;
    (void)data;
    stop_worker();
    pthread_mutex_lock(&engine.mutex);
    if (engine.notify_fd >= 0) close(engine.notify_fd);
    engine.notify_fd = -1;
    pthread_mutex_unlock(&engine.mutex);
    return env->intern(env, "nil");
}

static emacs_value engine_info(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) {
    (void)nargs;
    (void)args;
    (void)data;
#ifdef ETAF_MD_USE_CORETEXT
    const char *backend = "coretext";
#elif defined(ETAF_MD_USE_PANGO_DLOPEN)
    const char *backend = atomic_load(&pango_dlopen_active) ? "pango" : "pango-dlopen";
#elif defined(ETAF_MD_USE_PANGO)
    const char *backend = "pango";
#else
    const char *backend = "estimate";
#endif
    emacs_value items[] = {
        env->intern(env, ":engine"), env->make_string(env, "quickjs", 7),
        env->intern(env, ":pele"), env->make_string(env, "1.13.0", 6),
        env->intern(env, ":mathjax"), env->make_string(env, "3.2.2", 5),
        env->intern(env, ":text-backend"), env->make_string(env, backend, (ptrdiff_t)strlen(backend))
    };
    return env->funcall(env, env->intern(env, "list"), 8, items);
}

static void bind_function(emacs_env *env, const char *name, ptrdiff_t arity,
                          emacs_value (*function)(emacs_env *, ptrdiff_t, emacs_value *, void *),
                          const char *doc) {
    emacs_value args[] = {
        env->intern(env, name),
        env->make_function(env, arity, arity, function, doc, NULL)
    };
    env->funcall(env, env->intern(env, "fset"), 2, args);
}

EXPORT int emacs_module_init(struct emacs_runtime *runtime) {
    if (runtime->size < (ptrdiff_t)sizeof(*runtime)) return 1;
    emacs_env *env = runtime->get_environment(runtime);
    bind_function(
        env, "etaf-md--native-submit", 5, submit,
        "Submit ID, KIND (\"mermaid\" or \"math\"), SOURCE, OPTIONS-JSON and TIMEOUT-MS.");
    bind_function(
        env, "etaf-md--native-poll", 0, poll_result,
        "Return the next (ID JSON) result, or nil without blocking.");
    bind_function(
        env, "etaf-md--native-cancel", 1, cancel,
        "Cancel a queued or active native typeset request ID.");
    bind_function(
        env, "etaf-md--native-channel", 1, set_channel,
        "Attach Emacs pipe PROCESS for completion wakeups without spawning a child process.");
    bind_function(
        env, "etaf-md--native-shutdown", 0, shutdown_engine,
        "Stop the native worker thread and release queued work and JS runtime memory.");
    bind_function(
        env, "etaf-md--native-info", 0, engine_info,
        "Return metadata plist describing the loaded native typesetting engine.");
    emacs_value feature = env->intern(env, "etaf-md-typeset-native");
    env->funcall(env, env->intern(env, "provide"), 1, &feature);
    atexit(stop_worker);
    return pending_exit(env) ? 1 : 0;
}
