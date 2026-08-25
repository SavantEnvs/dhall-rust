//! mayhem/kat — known-answer probe used by mayhem/test.sh.
//!
//! `cargo test` for this workspace links its own test binaries but the actual
//! functional oracle we want (parse -> typecheck -> normalize on real Dhall
//! source, with an exact asserted value) is easiest to pin down as a small
//! standalone probe rather than by threading `--skip` filters through upstream's
//! `dhall/tests/spec.rs` (which also contains network-dependent `import/`
//! categories we deliberately do not run offline — see mayhem/test.sh).
//!
//! Built with the project's NORMAL (non-nightly, non-sanitized) flags in
//! build.sh, so it is a plain dynamically-linked Rust binary (Rust binaries
//! dynamically link libc by default) and therefore reachable by verify-repo's
//! LD_PRELOAD sabotage shim: a neutered build prints nothing and every
//! `kat_expect` in test.sh fails.
//!
//! Every line below is `KEY=VALUE`; test.sh grep -x matches full lines, so the
//! printed form must be exactly reproduced in test.sh's expected strings.

use dhall::{Ctxt, Parsed};

fn run(cx: Ctxt<'_>, label: &str, src: &str) {
    let parsed = match Parsed::parse_str(src) {
        Ok(p) => p,
        Err(e) => {
            println!("KAT_{label}_ERROR=parse: {e}");
            return;
        }
    };
    let resolved = match parsed.skip_resolve(cx) {
        Ok(r) => r,
        Err(e) => {
            println!("KAT_{label}_ERROR=resolve: {e}");
            return;
        }
    };
    let typed = match resolved.typecheck(cx) {
        Ok(t) => t,
        Err(e) => {
            println!("KAT_{label}_ERROR=typecheck: {e}");
            return;
        }
    };
    let ty = typed.get_type().expect("typed value always has a type");
    let normalized = typed.normalize(cx);
    println!("KAT_{label}_TYPE={}", ty.to_expr(cx));
    println!("KAT_{label}_VALUE={}", normalized.to_expr(cx));
}

fn main() {
    Ctxt::with_new(|cx| {
        // Natural arithmetic through a let-bound function (exercises the
        // parser's operator grammar, beta reduction, and Natural/+ builtin).
        run(cx, "ARITH", "let double = \\(x : Natural) -> x + x in double 21");

        // Text concatenation (Text/++ builtin).
        run(cx, "TEXT", "\"hello\" ++ \" \" ++ \"world\"");

        // List concatenation + record construction (exercises record/list
        // AST nodes and the printer's aggregate-formatting code paths).
        run(
            cx,
            "RECORD",
            "{ nums = [ 1, 2, 3 ] # [ 4, 5 ], flag = True && False }",
        );

        // A rejected (ill-typed) expression: proves the typechecker actually
        // rejects bad input rather than accepting everything.
        match Parsed::parse_str("1 + True")
            .expect("parses fine, it's just ill-typed")
            .skip_resolve(cx)
            .expect("no imports")
            .typecheck(cx)
        {
            Ok(_) => println!("KAT_ILLTYPED_UNEXPECTED_OK"),
            Err(_) => println!("KAT_ILLTYPED_REJECTED=yes"),
        }
    });
}
