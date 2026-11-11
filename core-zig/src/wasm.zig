//! WebAssembly entry point. The module's interface is the C ABI
//! (`capi.zig`, `Sources/CMisstype/include/misstype.h`) compiled for
//! wasm32-wasi; there is no browser-only API. The JavaScript binding is
//! packages/misstype-wasm (the site, the video renderer and the Obsidian
//! plugin all go through it).
//!
//! Build: `cd core-zig && zig build wasm` -> zig-out/wasm/misstype.wasm
//! (ReleaseSmall). `_start` is an empty main so WASI hosts can start it.
comptime {
    _ = @import("capi.zig");
}

pub fn main() void {}
