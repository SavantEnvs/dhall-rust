#![no_main]
//! fuzz_parse — exercises only `dhall::Parsed::parse_str`: the pest/pest_consume
//! grammar (dhall/src/syntax/text/parser.rs) that turns raw Dhall source text into
//! an AST. Pure function of the input bytes: no filesystem, no network, no env
//! vars — every byte the fuzzer produces is used only to build a `&str` handed
//! straight to the parser.

use dhall::Parsed;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(s) = std::str::from_utf8(data) else {
        return;
    };
    let _ = Parsed::parse_str(s);
});
