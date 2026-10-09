//! MisstypeCore in Zig (docs/zig-port.md). Swift `MisstypeCore` remains the
//! source of truth until the port reaches parity.

pub const unicode = @import("unicode.zig");
pub const keyboard = @import("keyboard.zig");
pub const punctuation = @import("punctuation.zig");
pub const composition = @import("composition.zig");
pub const candidate = @import("candidate.zig");
pub const user_lexicon = @import("user_lexicon.zig");
pub const user_dictionary = @import("user_dictionary.zig");
pub const channel = @import("channel.zig");
pub const lexicon = @import("lexicon.zig");
pub const english = @import("english.zig");
pub const layout = @import("layout.zig");
pub const storage = @import("storage.zig");
pub const touch = @import("touch.zig");
pub const keybindings = @import("keybindings.zig");
pub const session = @import("session.zig");
pub const Lexicon = lexicon.Lexicon;
pub const Syllable = keyboard.Syllable;

test {
    @import("std").testing.refAllDecls(@This());
    // Behavior suites ported from the Swift MisstypeCoreTests.
    _ = @import("tests/session_test.zig");
    _ = @import("tests/core_test.zig");
    _ = @import("tests/caret_test.zig");
    _ = @import("tests/latin_digit_test.zig");
    _ = @import("tests/bindings_test.zig");
    _ = @import("tests/keymap_test.zig");
    _ = @import("tests/mixed_test.zig");
    _ = @import("tests/repair_test.zig");
    _ = @import("tests/touch_test.zig");
}
