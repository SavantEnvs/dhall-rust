#![no_main]
//! fuzz_typecheck — the full pure pipeline: parse -> resolve -> typecheck ->
//! normalize -> print back to Dhall syntax. Exercises the type inference engine
//! (dhall/src/semantics/tck) and the normalizer (dhall/src/semantics/nze) on top
//! of the parser, all pure functions of the input bytes.
//!
//! Uses `skip_resolve` rather than `resolve`: `resolve` would perform real
//! filesystem/HTTP imports for any `Import` node in the source (network access
//! from inside a fuzz target is exactly the kind of non-determinism/hang risk
//! SPEC forbids), whereas `skip_resolve` just turns any `Import` node into an
//! immediate `Error` and never leaves the process. See
//! dhall/src/semantics/resolve/resolve.rs:558 ("Resolves names, and errors if we
//! find any imports.").
//!
//! Known upstream hang class (not fixed here, just documented): Dhall's
//! normalizer is Turing-incomplete (no unbounded recursion in the surface
//! language), but repeated function application / nested `let`s can still make
//! beta-reduction blow up exponentially in output size for a linear-size input
//! (a well-known class of DoS in every Dhall implementation, not specific to
//! dhall-rust). We bound the damage at the Mayhemfile level (`timeout: 30`) so a
//! single such input becomes a libFuzzer-reported timeout instead of stalling
//! the whole campaign; see mayhem/Mayhemfile_fuzz_typecheck.

use dhall::{Ctxt, Parsed};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(s) = std::str::from_utf8(data) else {
        return;
    };
    Ctxt::with_new(|cx| {
        let Ok(parsed) = Parsed::parse_str(s) else {
            return;
        };
        let Ok(resolved) = parsed.skip_resolve(cx) else {
            return;
        };
        let Ok(typed) = resolved.typecheck(cx) else {
            return;
        };
        let normalized = typed.normalize(cx);
        let _ = normalized.to_expr(cx);
    });
});
