# The Native Module

EKP can compute line breaks in a C dynamic module instead of Emacs Lisp. The module is optional: it is a build artifact of the package's `native/` directory, it is loaded explicitly, and every result it produces is checked against the Emacs Lisp engine before it is used. What it buys is speed — it runs the same dynamic program in compiled code and plans the paragraphs of a multi-paragraph string in parallel — and what it must never do is change the layout, so the interface around it is small and its failure modes are explicit.

This chapter defines the module's build and load commands and the condition that reports a backend that broke its contract. The options that decide when a loaded module is used are `ekp-use-c-module` and `ekp-auto-justify-native-append`, documented in [Parameter Reference](ekp-parameters.md); the model that the module computes is [Line-Breaking Principles](ekp-principles.md).

## The module boundary

<!-- index: native module; build profile; thread pool; backend contract; fallback -->

The module accelerates exactly one stage of the layout pipeline: the break search. Everything font-dependent stays in Emacs Lisp — tokenization, measurement, the box and glue arrays, hyphenation and the cache keys — and is passed to the module as arrays. The module therefore runs the same Knuth-Plass dynamic program on the same data, which is why its result can be required to match the Emacs Lisp engine exactly wherever both are available.

The module is a shared library in the package's `native/` directory, named `ekp` with the platform's suffix. It is built with `make` from that directory; the build profiles choose the compiler settings, from a portable optimized build to a native-CPU build with link-time optimization, a debug build, and a build with address and undefined-behavior sanitizers. Building never happens implicitly: the module is loaded by an explicit command, and requiring EKP does not load it.

Once loaded, the module serves two paths. A single-paragraph justification calls the one-paragraph entry point with the prepared arrays. A string with several paragraphs goes through the batch entry point, which processes one task per paragraph on a pool of worker threads; the pool is created lazily on the first such batch and its size follows the machine's processor count, capped at a fixed maximum. A full queue blocks the submitting thread rather than dropping a paragraph.

The module is versioned, and EKP requires a minimum version. A module below it is disabled at load time rather than used, which prevents an upgraded Elisp layer from calling an interface that changed underneath it. When the module is absent, too old, or returns a soft failure such as no result at all, the Emacs Lisp engine computes the paragraph instead, so layout is always available. The two engines are exercised against each other by the package's parity tests.

The loaded module is trusted only as far as the data it returns. Every non-nil result is validated: the break list must be a proper increasing list of box indices ending at the paragraph's box count, and the cost must be a number. A result that fails validation raises a contract error instead of being rendered. A nil result and a nil break list are the documented soft failures and mean "fall back to Emacs Lisp", not an error; the difference matters because a partial failure must never silently produce a different layout.

## Building and loading

#### Function: ekp-c-module-build (&optional profile)

Build the C module with make using PROFILE.

**Arguments.** PROFILE is one of `portable` (the default), `native`, `debug` or `sanitize`. `portable` is an optimized build that runs anywhere; `native` adds the build machine's instruction set and link-time optimization; `debug` and `sanitize` trade speed for diagnostics. Interactive calls prompt for the profile with `portable` preselected.

**Semantics.** The build runs `make PROFILE=…` in the package's `native/` directory asynchronously, so the command returns while the compiler works and the build output goes to a dedicated buffer. When the build exits successfully the freshly built module is loaded and the result reported; when it fails, the build buffer is displayed with the compiler output and the exit status is reported. Because the build reloads the module on success, one command both compiles and activates it.

**Returns.** Unspecified; the build and its load are the effect.

**Errors.** `error→ user-error` with the message `Unknown EKP C build profile: PROFILE` when PROFILE is not one of the four names, `Makefile not found in native/ directory` when the package has no `native/Makefile`, and `The make executable is not available` when `make` cannot be found. A compiler failure is not an error signal: it is reported in the build buffer.

**Example.**

```elisp
(ekp-c-module-build 'native)
     ⇒ compilation starts in the background and, on success, loads the built module
```

**See also.** `ekp-c-module-load`, `ekp-backend-contract-error`.

#### Function: ekp-c-module-load ()

Load EKP C module if available.

**Arguments.** None.

**Semantics.** It looks for the module library in the package's `native/` directory, using the platform suffix. When the file is missing, it reports that and leaves the module unloaded. When the file exists, it loads it from a temporary copy so that a module rebuilt earlier in the session can be loaded over the old one with the same command, initializes it, and checks its version against the minimum this EKP requires. A version below the minimum is disabled with a message telling the caller to rebuild and that Emacs Lisp will be used instead; a compatible module is enabled and the version and worker-thread count are reported. Loading is explicit and idempotent: requiring the package never does it.

**Returns.** Unspecified; enabling or disabling the module is the effect.

**Errors.** None of its own. Every outcome, including a missing or too-old module, is reported in the echo area while the Emacs Lisp engine stays usable.

**See also.** `ekp-c-module-build`, `ekp-use-c-module`.

## The backend contract

The module and the Emacs Lisp engine speak through a value contract: a computation returns a cons of the break list and the total cost, or nil. The contract has three failure classes with three different responses. A nil whole result or a nil break list is a soft failure and falls back to Emacs Lisp, because it can legitimately mean that this paragraph is not representable in the module's interface. A malformed non-nil result is a contract violation and signals, because rendering it would mean rendering a layout neither engine chose. And a signal raised by the module itself propagates unchanged through the public formatter; the dispatcher does not catch it and hide it.

This design keeps the fast path from ever becoming a different algorithm: a module that is absent, incompatible or partially failing degrades to the Emacs Lisp result, and a module that returns nonsense stops the call instead of publishing the nonsense.

#### Error: ekp-backend-contract-error

Malformed C backend result.

**Semantics.** The condition is signaled when the native module returns a non-nil result that fails validation. Its data is a list whose first element names the failure and whose second element is the offending result: `malformed-result` when the result is not a cons, `nonnumeric-cost` when the cost is not a number, and `malformed-breaks` when the break list is not a proper increasing list of box indices ending at the paragraph's box count. A nil result and a nil break list are deliberately excluded: they fall back to Emacs Lisp and do not signal.

**Recovery.** The mismatch means that the loaded module does not belong to this Emacs Lisp layer, most often because the module is stale after an upgrade. Rebuild it with `ekp-c-module-build`, or rebuild with `make` in `native/` and call `ekp-c-module-load`; until then, setting `ekp-use-c-module` to nil forces the Emacs Lisp engine and keeps the package usable. Nothing was published from the malformed result, so there is no layout state to repair.

**See also.** `ekp-c-module-load`, `ekp-c-module-build`, `ekp-use-c-module`.

## Errors and recovery

Nothing in this chapter is required for correct layout. A missing module, an incompatible module and a soft failure all leave the Emacs Lisp engine in charge, so the failure mode of the fast path is slower typesetting rather than no typesetting. The build command is the only entry point that signals for user mistakes, all of them before any compilation starts: an unknown profile, a missing Makefile, or a missing `make`; the compiler itself reports through its buffer.

A contract error is the one outcome that stops a call, and it is deliberate. It means the module returned something neither engine chose, so the safe response is to refuse the result and let the caller fix the module: rebuild it, reload it, or disable it for the session with `ekp-use-c-module` nil. Reloading is cheap, and loading from a temporary copy means a rebuild does not require restarting Emacs.
