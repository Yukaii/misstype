//! MisstypeCore in Zig (spike, docs/zig-port.md). Swift `MisstypeCore`
//! remains the source of truth until the port reaches parity.

pub const keyboard = @import("keyboard.zig");
pub const lexicon = @import("lexicon.zig");
pub const Lexicon = lexicon.Lexicon;
pub const Syllable = keyboard.Syllable;

test {
    @import("std").testing.refAllDecls(@This());
}
