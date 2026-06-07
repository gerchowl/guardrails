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

inventory::collect!(Tunable);

/// Compile-time, behaviour-defining constant — registered + justified.
/// `const_tunable!(pub const FRICTION: f32 = 1.6; "arcball decay ~2s to settle");`
#[macro_export]
macro_rules! const_tunable {
    ($(#[$m:meta])* $vis:vis const $name:ident : $ty:ty = $val:expr; $reason:expr $(;)?) => {
        $(#[$m])* $vis const $name: $ty = $val;
        $crate::inventory::submit! {
            $crate::Tunable {
                name: stringify!($name),
                repr: stringify!($val),
                kind: $crate::Kind::Const,
                reason: $reason,
                module: module_path!(),
            }
        }
    };
}

/// Operator/deploy-tunable default — registered, and meant to be backed by your config layer.
/// `config!(pub const GALAXY_N: u32 = 500_000; "startup particle count");`
#[macro_export]
macro_rules! config {
    ($(#[$m:meta])* $vis:vis const $name:ident : $ty:ty = $val:expr; $reason:expr $(;)?) => {
        $(#[$m])* $vis const $name: $ty = $val;
        $crate::inventory::submit! {
            $crate::Tunable {
                name: stringify!($name),
                repr: stringify!($val),
                kind: $crate::Kind::Config,
                reason: $reason,
                module: module_path!(),
            }
        }
    };
}

/// Every registered tunable in the linked binary (sorted: Config first, then by module/name).
pub fn all() -> Vec<&'static Tunable> {
    let mut v: Vec<&'static Tunable> = inventory::iter::<Tunable>().into_iter().collect();
    v.sort_by(|a, b| {
        (a.kind as u8, a.module, a.name).cmp(&(b.kind as u8, b.module, b.name))
    });
    v
}

/// Render the registry as the `TUNABLES.md` audit surface.
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
pub fn write_markdown(path: &str) -> std::io::Result<()> {
    std::fs::write(path, render_markdown())
}

#[cfg(test)]
mod tests {
    use super::*;

    const_tunable!(const SAMPLE_FRICTION: f32 = 1.6; "test: arcball decay");
    config!(const SAMPLE_N: u32 = 500_000; "test: startup count");

    #[test]
    fn registered_and_enumerable() {
        let names: Vec<_> = all().iter().map(|t| t.name).collect();
        assert!(names.contains(&"SAMPLE_FRICTION"));
        assert!(names.contains(&"SAMPLE_N"));
        // values are usable as real constants
        assert_eq!(SAMPLE_FRICTION, 1.6);
        assert_eq!(SAMPLE_N, 500_000);
    }

    #[test]
    fn markdown_has_entries_and_kinds() {
        let md = render_markdown();
        assert!(md.contains("SAMPLE_FRICTION") && md.contains("| const |"));
        assert!(md.contains("SAMPLE_N") && md.contains("| config |"));
        assert!(md.contains("`1.6`")); // the literal as written
    }
}
