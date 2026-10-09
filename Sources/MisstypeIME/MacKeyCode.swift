import CMisstype
import MisstypeMacKit
import MisstypeZigBridge

/// macOS virtual key code (ANSI position) -> neutral key. The table lives in
/// the Zig core (`misstype_key_from_mac`), shared with the C ABI's tests.
enum MacKeyCode {
    static func key(_ code: Int) -> KeyEvent.Key {
        let (kind, label) = ZigEngine.macKey(code)
        switch kind {
        case MISSTYPE_KEY_CHARACTER: return .character(label ?? "")
        case MISSTYPE_KEY_SPACE: return .space
        case MISSTYPE_KEY_ENTER: return .enter
        case MISSTYPE_KEY_TAB: return .tab
        case MISSTYPE_KEY_BACKSPACE: return .backspace
        case MISSTYPE_KEY_FORWARD_DELETE: return .forwardDelete
        case MISSTYPE_KEY_ESCAPE: return .escape
        case MISSTYPE_KEY_LEFT: return .left
        case MISSTYPE_KEY_RIGHT: return .right
        case MISSTYPE_KEY_UP: return .up
        case MISSTYPE_KEY_DOWN: return .down
        case MISSTYPE_KEY_PAGE_UP: return .pageUp
        case MISSTYPE_KEY_PAGE_DOWN: return .pageDown
        case MISSTYPE_KEY_SHIFT_LEFT: return .shift(.left)
        case MISSTYPE_KEY_SHIFT_RIGHT: return .shift(.right)
        case MISSTYPE_KEY_MODIFIER: return .modifier
        default: return .other
        }
    }
}
