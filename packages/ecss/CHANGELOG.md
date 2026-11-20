# Changelog

All notable changes to `ecss` are documented here.

## 0.1.0 (Unreleased)

### Removed

- The package manual `docs/manual.md` is replaced by the [ECSS chapters](https://etaf.top/ecss-schema-packages/) of the ETAF Reference Manual, which the README and the package Commentary link; `docs/architecture.md` remains the maintainer contract.

### Changed

- Selector locality classification accepts an optional proof of stable scope-root
  relationships, allowing hosts to reuse local anchored matches without treating
  structural selectors as local.

- Scoped style computation reuses mounted rule snapshots instead of copying
  every rule for each subject. Value resolvers receive detached mutable values
  so callback edits cannot alter subsequent stylesheet computations.

- Mounted scopes accept `:subjects` to snapshot explicit rule targets, including
  caller-authored content below another component. Structural matching and
  inheritance retain the host tree's semantics. The optional parent argument to
  `ecss-scope-create` is now passed as `:parent PARENT` instead of positionally.

- Hosts can validate concrete declaration values and identify ECSS-tagged
  values through public helpers without accessing internal representations.

- Static `.ecss` files now contain an unquoted rule list. Remove the outer
  quote from existing files. `ecss-read-rules` and `ecss-validate-rules` share
  inert rule syntax with file loading; wrappers and trailing forms are rejected.

- Expose the package entry at the repository root, document supported APIs in
  its Commentary and retain implementations under `lisp/`. Source consumers add
  the repository root to `load-path` and require the package entry; internal
  feature imports are unsupported. Archives retain this same directory layout.


### Added

- Independent property schemas, generic subjects and adapters, selector parsing and matching, stylesheets, complete cascade ordering, CSS-wide values, custom properties, computed values, diagnostics, and provenance.
- Pure Ebox-neutral public APIs with no TP dependency and no Buffer mutation.
- `ecss-merge-declarations` for shorthand-aware, presence-preserving composition of direct declaration groups.
- Standalone tests and compile, checkdoc, package-lint, and whitespace verification targets.
