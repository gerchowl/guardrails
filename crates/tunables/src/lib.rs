//! guardrails-tunables — declare a tunable *at its definition site*; it auto-registers into one
//! central, scannable registry you generate as `TUNABLES.md`.
//!
//! This is the decorator→registry pattern: it gives you the co-location of an inline annotation
//! AND the single-file audit surface of an allowlist — *generated from the code, so it can't drift*
//! (no orphaned entries, no two-places-to-edit). Two tiers:
//!   * [`const_tunable!`] — compile-time, behaviour-defining (gravity, friction, workgroup size).
//!     Registered + justified, but NOT runtime-overridable (you'd never set `workgroup_size` via env).
//!   * [`config!`] — operator/deploy-tunable (window size, counts, paths). Registered too, and meant
//!     to be backed by your config layer (RON/env).
//!
//! Both land in the same registry → assess every magic value from one file, never grep the codebase.
//!
//! ## wasm / no-registry consumers
//!
//! The registry rides on `inventory` (link-time collection), which `wasm32` targets don't support.
//! The macros still work everywhere: on wasm the registration expands to nothing and only the
//! `const` is emitted, so **a crate built for BOTH native and wasm (a GPU sim compiled to a browser
//! fixture, say) declares its knobs once** — native builds register them, wasm builds just get the
//! constants. If a target chokes on merely *compiling* `inventory`, depend per-target:
//!
//! ```toml
//! [target.'cfg(not(target_arch = "wasm32"))'.dependencies]
//! guardrails-tunables = { git = "…" }
//! [target.'cfg(target_arch = "wasm32")'.dependencies]
//! guardrails-tunables = { git = "…", default-features = false }
//! ```

#[cfg(all(feature = "registry", not(target_arch = "wasm32")))]
pub use inventory;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// Compile-time constant; behaviour-defining; not runtime-overridable.
    Const,
    /// Operator/deploy-tunable; should be backed by the config layer.
    Config,
}

/// One registered tunable. Collected via `inventory` at link time → enumerable with [`all`].
pub struct Tunable {
    pub name: &'static str,
    pub repr: &'static str, // the literal as written (`stringify!`)
    pub kind: Kind,
    pub reason: &'static str,
    pub module: &'static str,
}

#[cfg(all(feature = "registry", not(target_arch = "wasm32")))]
inventory::collect!(Tunable);

/// Registration plumbing behind [`const_tunable!`]/[`config!`] — registers on native builds with
/// the `registry` feature (default), expands to nothing on wasm / `default-features = false`.
/// The cfg sits on the macro DEFINITIONS, so it resolves against THIS crate's build for the active
/// target — consumers never need feature plumbing of their own.
#[cfg(all(feature = "registry", not(target_arch = "wasm32")))]
#[doc(hidden)]
#[macro_export]
macro_rules! __register {
    ($name:ident, $val:expr, $kind:ident, $reason:expr) => {
        $crate::inventory::submit! {
            $crate::Tunable {
                name: stringify!($name),
                repr: stringify!($val),
                kind: $crate::Kind::$kind,
                reason: $reason,
                module: module_path!(),
            }
        }
    };
}

#[cfg(not(all(feature = "registry", not(target_arch = "wasm32"))))]
#[doc(hidden)]
#[macro_export]
macro_rules! __register {
    ($name:ident, $val:expr, $kind:ident, $reason:expr) => {};
}

/// Compile-time, behaviour-defining constant — registered + justified.
/// `const_tunable!(pub const FRICTION: f32 = 1.6, "arcball decay ~2s to settle");`
///
/// **Why a comma (not `;`) before the reason:** the original `= 1.6; "reason"` form was
/// rustfmt-HOSTILE — rustfmt parses the parenthesized contents as items and rewrites them into
/// `= 1.6;, "reason"`, which matches no macro arm, so a plain `cargo fmt` broke the build (and
/// guardrails itself gates `rustfmt --check`…). The comma form starts with `pub`/`const`, which
/// rustfmt can't parse as an expression list, so it leaves the invocation verbatim — proven
/// fmt-stable in production use. The `;` arm is deliberately NOT kept for compatibility: any
/// `;` call site self-destructs on the consumer's first `cargo fmt`.
#[macro_export]
macro_rules! const_tunable {
    ($(#[$m:meta])* $vis:vis const $name:ident : $ty:ty = $val:expr, $reason:expr $(,)?) => {
        $(#[$m])* $vis const $name: $ty = $val;
        $crate::__register!($name, $val, Const, $reason);
    };
}

/// Operator/deploy-tunable default — registered, and meant to be backed by your config layer.
/// `config!(pub const GALAXY_N: u32 = 500_000, "startup particle count");`
/// (Comma separator — see [`const_tunable!`] on rustfmt stability.)
#[macro_export]
macro_rules! config {
    ($(#[$m:meta])* $vis:vis const $name:ident : $ty:ty = $val:expr, $reason:expr $(,)?) => {
        $(#[$m])* $vis const $name: $ty = $val;
        $crate::__register!($name, $val, Config, $reason);
    };
}

/// Every registered tunable in the linked binary (sorted: Config first, then by module/name).
#[cfg(all(feature = "registry", not(target_arch = "wasm32")))]
pub fn all() -> Vec<&'static Tunable> {
    let mut v: Vec<&'static Tunable> = inventory::iter::<Tunable>().into_iter().collect();
    v.sort_by(|a, b| (a.kind as u8, a.module, a.name).cmp(&(b.kind as u8, b.module, b.name)));
    v
}

/// Render the registry as the `TUNABLES.md` audit surface.
#[cfg(all(feature = "registry", not(target_arch = "wasm32")))]
pub fn render_markdown() -> String {
    let mut s = String::from(
        "# Tunables registry\n\n_Generated from `const_tunable!`/`config!` — do not edit by hand._\n\n\
         | Kind | Name | Value | Module | Reason |\n|------|------|-------|--------|--------|\n",
    );
    for t in all() {
        let kind = match t.kind {
            Kind::Const => "const",
            Kind::Config => "config",
        };
        s.push_str(&format!(
            "| {kind} | `{}` | `{}` | `{}` | {} |\n",
            t.name, t.repr, t.module, t.reason
        ));
    }
    s
}

/// Write `TUNABLES.md` (or any path).
#[cfg(all(feature = "registry", not(target_arch = "wasm32")))]
pub fn write_markdown(path: &str) -> std::io::Result<()> {
    std::fs::write(path, render_markdown())
}

#[cfg(test)]
mod tests {
    use super::*;

    const_tunable!(const SAMPLE_FRICTION: f32 = 1.6, "test: arcball decay");
    config!(const SAMPLE_N: u32 = 500_000, "test: startup count");
    const_tunable!(pub const SAMPLE_GAIN: f32 = 0.01, "test: comma form with visibility");
    config!(const SAMPLE_W: u32 = 256, "test: comma form config");

    #[test]
    fn constants_are_usable_everywhere() {
        // The consts exist regardless of registry availability (wasm / default-features = false).
        assert_eq!(SAMPLE_FRICTION, 1.6);
        assert_eq!(SAMPLE_N, 500_000);
    }

    #[cfg(all(feature = "registry", not(target_arch = "wasm32")))]
    #[test]
    fn registered_and_enumerable() {
        let names: Vec<_> = all().iter().map(|t| t.name).collect();
        assert!(names.contains(&"SAMPLE_FRICTION"));
        assert!(names.contains(&"SAMPLE_N"));
        assert!(
            names.contains(&"SAMPLE_GAIN"),
            "comma form must register too"
        );
        assert!(names.contains(&"SAMPLE_W"));
    }

    #[test]
    fn comma_form_consts_usable() {
        assert_eq!(SAMPLE_GAIN, 0.01);
        assert_eq!(SAMPLE_W, 256);
    }

    #[cfg(all(feature = "registry", not(target_arch = "wasm32")))]
    #[test]
    fn markdown_has_entries_and_kinds() {
        let md = render_markdown();
        assert!(md.contains("SAMPLE_FRICTION") && md.contains("| const |"));
        assert!(md.contains("SAMPLE_N") && md.contains("| config |"));
        assert!(md.contains("`1.6`")); // the literal as written
    }
}
