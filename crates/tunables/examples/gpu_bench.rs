//! Demo: the gpu-bench magic numbers, declared as tunables. `cargo run --example gpu_bench`
//! writes TUNABLES.md — the single audit surface for every blessed value.

use guardrails_tunables::{config, const_tunable, write_markdown};

// Arcball (behaviour-defining → const_tunable).
const_tunable!(pub const DRAG_GAIN: f32 = 0.01, "arcball: radians of rotation per pixel of drag");
const_tunable!(pub const FRICTION: f32 = 1.6, "arcball spin decay; ~2s to settle");
const_tunable!(pub const HOME_ZOOM: f32 = 16.0, "eye distance framing the galaxy disk at a 3/4 view");

// Galaxy physics (behaviour-defining).
const_tunable!(pub const GRAVITY: f32 = 9.0, "central well strength");
const_tunable!(pub const SOFTENING: f32 = 0.30, "added to r^2 to bound the 1/r^2 singularity");
const_tunable!(pub const WORKGROUP: u32 = 256, "compute workgroup size (must match WGSL)");

// Operator-tunable defaults (→ config, backed by env/RON at runtime).
config!(pub const GALAXY_DEFAULT_N: u32 = 500_000, "startup particle count");
config!(pub const RAMP_TARGET_FPS: f32 = 58.0, "auto-ramp 60-fps-ceiling target");

fn main() {
    let _ = (
        DRAG_GAIN,
        FRICTION,
        HOME_ZOOM,
        GRAVITY,
        SOFTENING,
        WORKGROUP,
        GALAXY_DEFAULT_N,
        RAMP_TARGET_FPS,
    );
    write_markdown("TUNABLES.md").expect("write TUNABLES.md");
    eprintln!(
        "[tunables] wrote TUNABLES.md ({} registered)",
        guardrails_tunables::all().len()
    );
}
