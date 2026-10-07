// Standard (Dai-Chien) Zhuyin keyboard: symbol -> KeyboardEvent.code/key,
// the same pair the playground passes to misstype_wasm_handle_key.
const rows: [string, string][] = [
  ["ㄅㄉˇˋㄓˊ˙ㄚㄞㄢㄦ", "1234567890-"],
  ["ㄆㄊㄍㄐㄔㄗㄧㄛㄟㄣ", "qwertyuiop"],
  ["ㄇㄋㄎㄑㄕㄘㄨㄜㄠㄤ", "asdfghjkl;"],
  ["ㄈㄌㄏㄒㄖㄙㄩㄝㄡㄥ", "zxcvbnm,./"],
];

const codeForChar: Record<string, string> = {
  "-": "Minus", ";": "Semicolon", ",": "Comma", ".": "Period", "/": "Slash",
};

export type Key = { code: string; key: string };

const table = new Map<string, Key>();
for (const [symbols, chars] of rows) {
  Array.from(symbols).forEach((symbol, i) => {
    const ch = chars[i];
    const code = codeForChar[ch] ?? (/[0-9]/.test(ch) ? `Digit${ch}` : `Key${ch.toUpperCase()}`);
    table.set(symbol, { code, key: ch });
  });
}

const named: Record<string, Key> = {
  Enter: { code: "Enter", key: "Enter" },
  Space: { code: "Space", key: " " },
  Down: { code: "ArrowDown", key: "ArrowDown" },
  Backspace: { code: "Backspace", key: "Backspace" },
};

export function keyFor(token: string): Key {
  const k = table.get(token) ?? named[token];
  if (!k) throw new Error(`No key for ${JSON.stringify(token)}`);
  return k;
}
