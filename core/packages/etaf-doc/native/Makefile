# Makefile for etaf-md native QuickJS typesetting module
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Build architecture inspired by LuciusChen/pele.el (https://github.com/LuciusChen/pele.el).

EMACS ?= emacs
PYTHON ?= python3
CC ?= cc
UNAME_S := $(shell uname -s)

MODULE_SUFFIX := $(shell $(EMACS) -Q --batch --eval '(princ (or module-file-suffix ".so"))' 2>/dev/null)
ifeq ($(strip $(MODULE_SUFFIX)),)
ifeq ($(UNAME_S),Darwin)
MODULE_SUFFIX := .dylib
else
MODULE_SUFFIX := .so
endif
endif

EMACS_INCLUDE ?= $(shell $(EMACS) -Q --batch --eval '(princ (file-name-directory (or (locate-file "emacs-module.h" (list (expand-file-name "../include" invocation-directory) (expand-file-name "../../../include" invocation-directory) "/Applications/Emacs.app/Contents/Resources/include" "/opt/homebrew/include" "/usr/local/include" "/usr/include")) "./emacs-module.h")))' 2>/dev/null)

MODULE := etaf-md-typeset-native$(MODULE_SUFFIX)

PANGO_PACKAGES := pangocairo
ifeq ($(UNAME_S),Linux)
PANGO_PACKAGES += pangofc fontconfig
endif
PANGO_CFLAGS := $(shell pkg-config --cflags $(PANGO_PACKAGES) 2>/dev/null)
PANGO_LIBS := $(shell pkg-config --libs $(PANGO_PACKAGES) 2>/dev/null)

TEXT_BACKEND ?= auto
PORTABLE ?= 0
ARCH ?=
FONT_BACKEND := $(TEXT_BACKEND)
ifeq ($(FONT_BACKEND),auto)
ifeq ($(UNAME_S),Darwin)
FONT_BACKEND := coretext
else ifeq ($(PORTABLE),1)
FONT_BACKEND := pango-dlopen
else ifneq ($(strip $(PANGO_LIBS)),)
FONT_BACKEND := pango
else
FONT_BACKEND := estimate
endif
endif

CPPFLAGS += -D_GNU_SOURCE -DCONFIG_VERSION='"2026-06-04"' -isystem vendor/quickjs -Ibuild -I$(EMACS_INCLUDE)
CFLAGS ?= -O2
CFLAGS += -std=gnu11 -fPIC -fvisibility=hidden -pthread
ifeq ($(UNAME_S),Darwin)
ifeq ($(PORTABLE),1)
CFLAGS += -mmacosx-version-min=12.0
LDFLAGS += -mmacosx-version-min=12.0
endif
ifneq ($(strip $(ARCH)),)
CFLAGS += -arch $(ARCH)
LDFLAGS += -arch $(ARCH)
endif
endif

CORE := quickjs dtoa libregexp libunicode cutils
OBJECTS := $(addprefix build/,$(addsuffix .o,$(CORE))) build/bundles.o build/etaf_md_typeset.o

ifeq ($(FONT_BACKEND),pango-dlopen)
CPPFLAGS += -DETAF_MD_USE_PANGO_DLOPEN
LDLIBS += -ldl
else ifeq ($(FONT_BACKEND),pango)
ifeq ($(strip $(PANGO_LIBS)),)
$(error Pango not found: install the pangocairo development package or build with TEXT_BACKEND=pango-dlopen)
endif
CPPFLAGS += -DETAF_MD_USE_PANGO $(PANGO_CFLAGS)
LDLIBS += $(PANGO_LIBS)
ifeq ($(UNAME_S),Linux)
CPPFLAGS += -DETAF_MD_USE_FONTCONFIG
endif
else ifeq ($(FONT_BACKEND),coretext)
ifneq ($(UNAME_S),Darwin)
$(error Core Text is only available on macOS)
endif
CPPFLAGS += -DETAF_MD_USE_CORETEXT
LDLIBS += -framework CoreText -framework CoreFoundation
else ifneq ($(FONT_BACKEND),estimate)
$(error Unknown TEXT_BACKEND: $(TEXT_BACKEND))
endif

ifeq ($(UNAME_S),Darwin)
SHARED_FLAGS := -dynamiclib
else
SHARED_FLAGS := -shared
endif

.PHONY: all clean info
all: $(MODULE)

build:
	mkdir -p build

build/bundles.h build/bundles.c: vendor/pele/pele.global.js vendor/mathjax/mathjax-tex-svg.global.js bridge.js embed.py | build
	$(PYTHON) embed.py build/bundles.h build/bundles.c vendor/pele/pele.global.js vendor/mathjax/mathjax-tex-svg.global.js bridge.js

build/%.o: vendor/quickjs/%.c $(wildcard vendor/quickjs/*.h) | build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

build/bundles.o: build/bundles.c build/bundles.h | build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

build/etaf_md_typeset.o: etaf_md_typeset.c build/bundles.h Makefile
	$(CC) $(CPPFLAGS) $(CFLAGS) -Wall -Wextra -Werror -c $< -o $@

$(MODULE): $(OBJECTS)
	$(CC) $(SHARED_FLAGS) $(LDFLAGS) -o $@ $(OBJECTS) $(LDLIBS) -lm -pthread
	@echo "Built $@ (text backend: $(FONT_BACKEND))"

clean:
	rm -rf build etaf-md-typeset-native.so etaf-md-typeset-native.dylib etaf-md-typeset-native.dll

info:
	@echo "CC: $(CC)"
	@echo "EMACS_INCLUDE: $(EMACS_INCLUDE)"
	@echo "FONT_BACKEND: $(FONT_BACKEND)"
	@echo "MODULE: $(MODULE)"
