// Hand-written Rust for examples/hatches.axum.rb. `rust_file "rust/shout.rs", as: :shout` copies this file
// into the emitted crate as module `shout`, and the two `rust_fn ... from: :shout` lines declare these
// functions' types. The compiler does not check this file (cargo does); every `pub fn` here is called
// from the example, because the crate builds with -Dwarnings and an unused one would fail it.

pub fn loud(s: &str) -> String {
    format!("{}!", s.to_uppercase())
}

pub fn first_word(s: &str) -> Option<String> {
    s.split_whitespace().next().map(|w| w.to_string())
}
