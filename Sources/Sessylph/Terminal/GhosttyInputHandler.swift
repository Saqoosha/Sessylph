import AppKit
@preconcurrency import GhosttyKit

enum GhosttyInputHandler {

    // MARK: - Modifier Translation

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }

    // MARK: - Key Translation

    static func ghosttyKey(from keyCode: UInt16) -> ghostty_input_key_e {
        keyCodeMap[keyCode] ?? GHOSTTY_KEY_UNIDENTIFIED
    }

    // MARK: - Mouse Button Translation

    static func ghosttyMouseButton(from buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        case 3: GHOSTTY_MOUSE_EIGHT
        case 4: GHOSTTY_MOUSE_NINE
        case 5: GHOSTTY_MOUSE_SIX
        case 6: GHOSTTY_MOUSE_SEVEN
        case 7: GHOSTTY_MOUSE_FOUR
        case 8: GHOSTTY_MOUSE_FIVE
        case 9: GHOSTTY_MOUSE_TEN
        case 10: GHOSTTY_MOUSE_ELEVEN
        default: GHOSTTY_MOUSE_UNKNOWN
        }
    }

    // MARK: - Scroll Mods

    static func scrollMods(precision: Bool, momentumPhase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var value: Int32 = 0
        if precision { value |= 0b0000_0001 }
        let momentum: UInt8
        switch momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        value |= Int32(momentum) << 1
        return value
    }

    // MARK: - Keycode Map (macOS keyCode → ghostty_input_key_e)
    // Based on Ghostty src/input/keycodes.zig

    private static let keyCodeMap: [UInt16: ghostty_input_key_e] = [
        // Writing System Keys
        0x0032: GHOSTTY_KEY_BACKQUOTE,
        0x002a: GHOSTTY_KEY_BACKSLASH,
        0x0021: GHOSTTY_KEY_BRACKET_LEFT,
        0x001e: GHOSTTY_KEY_BRACKET_RIGHT,
        0x002b: GHOSTTY_KEY_COMMA,
        0x001d: GHOSTTY_KEY_DIGIT_0,
        0x0012: GHOSTTY_KEY_DIGIT_1,
        0x0013: GHOSTTY_KEY_DIGIT_2,
        0x0014: GHOSTTY_KEY_DIGIT_3,
        0x0015: GHOSTTY_KEY_DIGIT_4,
        0x0017: GHOSTTY_KEY_DIGIT_5,
        0x0016: GHOSTTY_KEY_DIGIT_6,
        0x001a: GHOSTTY_KEY_DIGIT_7,
        0x001c: GHOSTTY_KEY_DIGIT_8,
        0x0019: GHOSTTY_KEY_DIGIT_9,
        0x0018: GHOSTTY_KEY_EQUAL,
        0x000a: GHOSTTY_KEY_INTL_BACKSLASH,
        0x005e: GHOSTTY_KEY_INTL_RO,
        0x005d: GHOSTTY_KEY_INTL_YEN,
        0x0000: GHOSTTY_KEY_A,
        0x000b: GHOSTTY_KEY_B,
        0x0008: GHOSTTY_KEY_C,
        0x0002: GHOSTTY_KEY_D,
        0x000e: GHOSTTY_KEY_E,
        0x0003: GHOSTTY_KEY_F,
        0x0005: GHOSTTY_KEY_G,
        0x0004: GHOSTTY_KEY_H,
        0x0022: GHOSTTY_KEY_I,
        0x0026: GHOSTTY_KEY_J,
        0x0028: GHOSTTY_KEY_K,
        0x0025: GHOSTTY_KEY_L,
        0x002e: GHOSTTY_KEY_M,
        0x002d: GHOSTTY_KEY_N,
        0x001f: GHOSTTY_KEY_O,
        0x0023: GHOSTTY_KEY_P,
        0x000c: GHOSTTY_KEY_Q,
        0x000f: GHOSTTY_KEY_R,
        0x0001: GHOSTTY_KEY_S,
        0x0011: GHOSTTY_KEY_T,
        0x0020: GHOSTTY_KEY_U,
        0x0009: GHOSTTY_KEY_V,
        0x000d: GHOSTTY_KEY_W,
        0x0007: GHOSTTY_KEY_X,
        0x0010: GHOSTTY_KEY_Y,
        0x0006: GHOSTTY_KEY_Z,
        0x001b: GHOSTTY_KEY_MINUS,
        0x002f: GHOSTTY_KEY_PERIOD,
        0x0027: GHOSTTY_KEY_QUOTE,
        0x0029: GHOSTTY_KEY_SEMICOLON,
        0x002c: GHOSTTY_KEY_SLASH,

        // Functional Keys
        0x003a: GHOSTTY_KEY_ALT_LEFT,
        0x003d: GHOSTTY_KEY_ALT_RIGHT,
        0x0033: GHOSTTY_KEY_BACKSPACE,
        0x0039: GHOSTTY_KEY_CAPS_LOCK,
        0x006e: GHOSTTY_KEY_CONTEXT_MENU,
        0x003b: GHOSTTY_KEY_CONTROL_LEFT,
        0x003e: GHOSTTY_KEY_CONTROL_RIGHT,
        0x0024: GHOSTTY_KEY_ENTER,
        0x0037: GHOSTTY_KEY_META_LEFT,
        0x0036: GHOSTTY_KEY_META_RIGHT,
        0x0038: GHOSTTY_KEY_SHIFT_LEFT,
        0x003c: GHOSTTY_KEY_SHIFT_RIGHT,
        0x0031: GHOSTTY_KEY_SPACE,
        0x0030: GHOSTTY_KEY_TAB,

        // Control Pad Section
        0x0075: GHOSTTY_KEY_DELETE,
        0x0077: GHOSTTY_KEY_END,
        0x0073: GHOSTTY_KEY_HOME,
        0x0072: GHOSTTY_KEY_INSERT,
        0x0079: GHOSTTY_KEY_PAGE_DOWN,
        0x0074: GHOSTTY_KEY_PAGE_UP,

        // Arrow Pad Section
        0x007d: GHOSTTY_KEY_ARROW_DOWN,
        0x007b: GHOSTTY_KEY_ARROW_LEFT,
        0x007c: GHOSTTY_KEY_ARROW_RIGHT,
        0x007e: GHOSTTY_KEY_ARROW_UP,

        // Numpad Section
        0x0047: GHOSTTY_KEY_NUM_LOCK,
        0x0052: GHOSTTY_KEY_NUMPAD_0,
        0x0053: GHOSTTY_KEY_NUMPAD_1,
        0x0054: GHOSTTY_KEY_NUMPAD_2,
        0x0055: GHOSTTY_KEY_NUMPAD_3,
        0x0056: GHOSTTY_KEY_NUMPAD_4,
        0x0057: GHOSTTY_KEY_NUMPAD_5,
        0x0058: GHOSTTY_KEY_NUMPAD_6,
        0x0059: GHOSTTY_KEY_NUMPAD_7,
        0x005b: GHOSTTY_KEY_NUMPAD_8,
        0x005c: GHOSTTY_KEY_NUMPAD_9,
        0x0045: GHOSTTY_KEY_NUMPAD_ADD,
        0x005f: GHOSTTY_KEY_NUMPAD_COMMA,
        0x0041: GHOSTTY_KEY_NUMPAD_DECIMAL,
        0x004b: GHOSTTY_KEY_NUMPAD_DIVIDE,
        0x004c: GHOSTTY_KEY_NUMPAD_ENTER,
        0x0051: GHOSTTY_KEY_NUMPAD_EQUAL,
        0x0043: GHOSTTY_KEY_NUMPAD_MULTIPLY,
        0x004e: GHOSTTY_KEY_NUMPAD_SUBTRACT,

        // Function Section
        0x0035: GHOSTTY_KEY_ESCAPE,
        0x007a: GHOSTTY_KEY_F1,
        0x0078: GHOSTTY_KEY_F2,
        0x0063: GHOSTTY_KEY_F3,
        0x0076: GHOSTTY_KEY_F4,
        0x0060: GHOSTTY_KEY_F5,
        0x0061: GHOSTTY_KEY_F6,
        0x0062: GHOSTTY_KEY_F7,
        0x0064: GHOSTTY_KEY_F8,
        0x0065: GHOSTTY_KEY_F9,
        0x006d: GHOSTTY_KEY_F10,
        0x0067: GHOSTTY_KEY_F11,
        0x006f: GHOSTTY_KEY_F12,
        0x0069: GHOSTTY_KEY_F13,
        0x006b: GHOSTTY_KEY_F14,
        0x0071: GHOSTTY_KEY_F15,
        0x006a: GHOSTTY_KEY_F16,
        0x0040: GHOSTTY_KEY_F17,
        0x004f: GHOSTTY_KEY_F18,
        0x0050: GHOSTTY_KEY_F19,
        0x005a: GHOSTTY_KEY_F20,

        // Media Keys
        0x0049: GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
        0x004a: GHOSTTY_KEY_AUDIO_VOLUME_MUTE,
        0x0048: GHOSTTY_KEY_AUDIO_VOLUME_UP,
    ]
}
