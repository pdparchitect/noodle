import Foundation
import Surface

/// Keys and typing from a remote viewer, played into an HTML noodlet's page as the key events a
/// keyboard gives. As Mac key events they went through the Mac's text input, which serves the
/// active window, so they reached other windows, opened the emoji picker and beeped.
public enum PageKeys {
  public static func script(for input: SurfaceInput) -> String? {
    var steps: [[String: Any]] = []
    switch input {
    case .pointer, .scroll: return nil
    case .hold(let key, let pressed): steps = [step(pressed ? "keydown" : "keyup", key)]
    case .key(let key):
      var down = step("keydown", key.rawValue)
      if key == .backspace { down["delete"] = true }
      steps = [down, step("keyup", key.rawValue)]
    case .text(let text):
      for character in text.prefix(4096) {
        let name = character == " " ? "space" : String(character)
        var down = step("keydown", name)
        down["insert"] = String(character)
        steps += [down, step("keyup", name)]
      }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: steps) else { return nil }
    return """
      const target = document.activeElement && document.activeElement !== document.body ? document.activeElement : (document.body || document.documentElement);
      const editable = target.isContentEditable || target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement;
      for (const s of \(String(decoding: data, as: UTF8.self))) {
        const typed = target.dispatchEvent(new KeyboardEvent(s.type, {key: s.key, code: s.code, keyCode: s.keyCode, which: s.keyCode, bubbles: true, cancelable: true, composed: true}));
        if (typed && editable && s.insert) document.execCommand('insertText', false, s.insert);
        if (typed && editable && s.delete) document.execCommand('delete');
      }
      """
  }

  /// A key as a keyboard reports it: named keys, lowercase letters and digits by their key, code
  /// and key code; anything else typed carries only its character.
  private static func step(_ type: String, _ name: String) -> [String: Any] {
    let named: [String: (String, String, Int)] = [
      "space": (" ", "Space", 32), "enter": ("Enter", "Enter", 13), "tab": ("Tab", "Tab", 9), "escape": ("Escape", "Escape", 27),
      "backspace": ("Backspace", "Backspace", 8), "left": ("ArrowLeft", "ArrowLeft", 37), "up": ("ArrowUp", "ArrowUp", 38),
      "right": ("ArrowRight", "ArrowRight", 39), "down": ("ArrowDown", "ArrowDown", 40),
    ]
    if let (key, code, keyCode) = named[name] { return ["type": type, "key": key, "code": code, "keyCode": keyCode] }
    if name.count == 1, let scalar = name.unicodeScalars.first, scalar.isASCII {
      let upper = name.uppercased()
      if ("a"..."z").contains(name.lowercased()) {
        return ["type": type, "key": name, "code": "Key" + upper, "keyCode": Int(upper.unicodeScalars.first!.value)]
      }
      if ("0"..."9").contains(name) { return ["type": type, "key": name, "code": "Digit" + name, "keyCode": Int(scalar.value)] }
    }
    return ["type": type, "key": name, "code": "", "keyCode": 0]
  }
}
