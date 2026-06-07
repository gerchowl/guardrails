# Tunables registry

_Generated from `const_tunable!`/`config!` — do not edit by hand._

| Kind | Name | Value | Module | Reason |
|------|------|-------|--------|--------|
| const | `DRAG_GAIN` | `0.01` | `gpu_bench` | arcball: radians of rotation per pixel of drag |
| const | `FRICTION` | `1.6` | `gpu_bench` | arcball spin decay; ~2s to settle |
| const | `GRAVITY` | `9.0` | `gpu_bench` | central well strength |
| const | `HOME_ZOOM` | `16.0` | `gpu_bench` | eye distance framing the galaxy disk at a 3/4 view |
| const | `SOFTENING` | `0.30` | `gpu_bench` | added to r^2 to bound the 1/r^2 singularity |
| const | `WORKGROUP` | `256` | `gpu_bench` | compute workgroup size (must match WGSL) |
| config | `GALAXY_DEFAULT_N` | `500_000` | `gpu_bench` | startup particle count |
| config | `RAMP_TARGET_FPS` | `58.0` | `gpu_bench` | auto-ramp 60-fps-ceiling target |
