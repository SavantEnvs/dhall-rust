#!/usr/bin/env bash
#
# dhall-rust/mayhem/test.sh — RUN the project's own inline unit tests plus the KAT
# probe, and emit a CTRF summary. exit 0 iff nothing failed. This script only RUNS
# things; build.sh did the building.
#
# Why not upstream's dhall/tests/spec.rs (the big golden-comparison suite)? Two
# independent reasons rule it out as the PATCH-tier oracle:
#   1. Its import_success/import_failure categories make LIVE HTTP requests to
#      real servers (dhall-lang's own `import/success/*A.dhall` fixtures) with no
#      local test server anywhere in dhall-rust's own test code — completely
#      incompatible with SPEC §6.5's air-gapped re-run.
#   2. ALL of its categories (not just import) read fixtures from the `dhall-lang`
#      git SUBMODULE. verify-repo.sh's own build-verify step deliberately builds
#      from a plain `git clone` of HEAD (matching what `actions/checkout` without
#      `submodules:` would produce), so the submodule directory is present but
#      EMPTY there — spec.rs would then discover zero tests in every category and
#      the run would look green for entirely the wrong reason (0 tests, not "all
#      passed"), or, once we guard against exactly that, hard-fail on a gap that
#      has nothing to do with the code under test.
# So the oracle here is deliberately submodule-free and network-free: upstream's
# own inline `#[test]`s (dhall/src, serde_dhall/src — genuine assertions, not
# fixture-driven) plus a small KAT probe. `test_grammar_files_in_sync`
# (dhall/src/syntax/text/parser.rs) is skipped for the same submodule reason —
# it diffs src/syntax/text/dhall.abnf against ../dhall-lang/standard/dhall.abnf.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) `cargo test --lib` for the `dhall` and `serde_dhall` crates: real
#     hand-written assertions (e.g. cache.rs's filename_for_hash golden SHA256,
#     value.rs's Display-format assertions) — behavior, not "exits 0".
#
#  2) The KAT probe /mayhem/kat — Rust test binaries ARE dynamically linked on
#     Linux by default (unlike Go's static default), so verify-repo's LD_PRELOAD
#     sabotage shim (a constructor that _exit(0)s every non-system executable)
#     can already neuter part (1) in principle. /mayhem/kat is the explicit,
#     always-run belt-and-suspenders check: it prints exact `KEY=VALUE` lines for
#     parse+typecheck+normalize results on a few fixed Dhall expressions plus a
#     rejected ill-typed expression; test.sh grep -x's each one verbatim. A
#     neutered /mayhem/kat prints nothing and every kat_expect below fails.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/rust/cargo/bin:$PATH"
: "${SRC:=/mayhem}"
: "${RUST_STABLE:=stable}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0; FAILED=0; SKIPPED=0

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-lib+kat" 0 1 0; exit 2
fi

# ── 1) upstream's own inline unit tests (submodule-free, network-free) ─────────
run_lib_tests() {
  local pkg="$1"; shift
  local OUT="$SRC/mayhem-build/cargotest-$pkg.out"
  mkdir -p "$SRC/mayhem-build"
  echo "=== running: cargo +$RUST_STABLE test -p $pkg --lib -- $* ==="
  cargo "+$RUST_STABLE" test -p "$pkg" --lib -- "$@" >"$OUT" 2>&1
  tail -10 "$OUT"
  # Standard cargo/libtest summary line: "test result: ok. P passed; F failed; S ignored; ..."
  local line; line="$(grep -m1 '^test result:' "$OUT" || true)"
  if [ -z "$line" ]; then
    echo "FAIL: no 'test result:' summary for package $pkg" >&2
    FAILED=$(( FAILED + 1 ))
    return
  fi
  local p f s
  p=$(printf '%s\n' "$line" | grep -oE '[0-9]+ passed'  | grep -oE '[0-9]+' || echo 0)
  f=$(printf '%s\n' "$line" | grep -oE '[0-9]+ failed'  | grep -oE '[0-9]+' || echo 0)
  s=$(printf '%s\n' "$line" | grep -oE '[0-9]+ ignored' | grep -oE '[0-9]+' || echo 0)
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); SKIPPED=$(( SKIPPED + s ))
  echo "  $pkg: $line"
}

# test_grammar_files_in_sync diffs against the dhall-lang SUBMODULE (see header) —
# skip it explicitly; everything else in these two crates' inline test modules is
# self-contained.
run_lib_tests dhall --skip test_grammar_files_in_sync
run_lib_tests serde_dhall

if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  echo "FAIL: no unit tests were counted at all — the suite did not run" >&2
  FAILED=$(( FAILED + 1 ))
fi

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts parsed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or parser broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "arithmetic (let + Natural/+)"    'KAT_ARITH_VALUE=42'
kat_expect "text concatenation"              'KAT_TEXT_VALUE="hello world"'
kat_expect "record/list construction"        'KAT_RECORD_VALUE={ flag = False, nums = [1, 2, 3, 4, 5] }'
kat_expect "ill-typed expression rejected"   'KAT_ILLTYPED_REJECTED=yes'

emit_ctrf "cargo-lib+kat" "$PASSED" "$FAILED" "$SKIPPED"
