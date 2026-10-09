# Mobile Zhuyin IME survey

Surveyed 2026-10-09 before choosing the first mobile implementation. The
question is whether Misstype should compete as a general-purpose keyboard or
use mobile to test its distinctive interaction: a split touch surface, delayed
whole-phrase decoding, coordinate-aware fuzzy repair, and offline traces.

## Existing products

| Platform | Product | What it already covers | Gap relevant to Misstype |
| --- | --- | --- | --- |
| iOS | Apple Chinese keyboard | The system offers Traditional Chinese Zhuyin input and candidate conversion. Third-party keyboards are installed as custom keyboard extensions. | A custom keyboard cannot run in secure or phone-pad fields; apps can reject custom keyboards; the extension has tight memory and integration limits. The system keyboard is a strong baseline for ordinary typing. |
| iOS | [Panda Zhuyin](https://apps.apple.com/sg/app/panda-zhuyin/id6761426494) | Offline Zhuyin, long-sentence conversion, learning, custom dictionary, candidate tabs, one-handed/landscape layouts, VoiceOver, and optional iCloud sync. | It is already a polished general-purpose Zhuyin keyboard. Misstype needs a measurable interaction advantage rather than another theme/dictionary keyboard. |
| iOS | [Keeboard](https://apps.apple.com/us/app/keeboard/id6761025252) | A private multilingual keyboard with Zhuyin, on-device predictions, snippets, voice typing, and language switching. | Broad multilingual coverage is already available; Misstype should stay focused on touch capture and repair. |
| iOS | [YiKey](https://apps.apple.com/eg/app/yikey/id6782687624) | Traditional Zhuyin, local candidates, Chinese/English translation workflow, and a voice pad. | Translation and voice are covered; they are outside Misstype's offline decoder thesis. |
| iOS | [CozyZhuyin Pro](https://apps.apple.com/us/app/cozyzhuyin-pro/id1152749877) | Large keys, familiar layout, one-handed use, cursor controls, themes, and no Full Access requirement. | Large conventional keys address touch accuracy directly, but the product does not expose a coordinate-aware trace/repair experiment. |
| iOS | [UrKeyboard](https://apps.apple.com/us/app/urkeyboard%E8%BC%B8%E5%85%A5%E6%B3%95/id898188878) | Multiple Traditional Chinese methods, continuous sentence input, custom layouts, themes, cursor control, learning, and optional cloud sync. | It covers breadth and personalization; Misstype's differentiator must be the capture/decode model and privacy-preserving replay. |
| Android | [Gboard](https://play.google.com/store/apps/details?id=com.google.android.inputmethod.latin) / Google Zhuyin | Mainstream Chinese keyboard with Zhuyin/Pinyin availability, candidate prediction, handwriting/voice and broad language support. | It is the default-quality baseline. A prototype must beat it on a specific touch/noise task, not general feature count. |
| Android | [Chaozhuyin](https://play.google.com/store/apps/details?id=tw.chaozhuyin) | Zhuyin, proximity correction, swiping, adjustable keyboard, candidate dropdown, English, phrase backup, tablet/hardware support. | This is the closest feature competitor and already validates demand for proximity correction. Misstype needs a stronger whole-phrase/touch-trace result and a privacy/offline story. |
| Android | [gcin](https://play.google.com/store/apps/details?id=com.hyperrate.gcin) | Multiple Taiwanese input methods, several Zhuyin layouts, candidate prediction, user dictionaries, physical keyboards, and configurable selection. | Very broad and mature; replacing it as a daily driver is the wrong first goal. |
| Android | [Guileless Bopomofo](https://f-droid.org/en/packages/org.ghostsinthelab.apps.guilelessbopomofo/) | Open-source, offline Bopomofo keyboard with physical-keyboard support and multiple layouts; available through F-Droid. | It is a privacy-aligned baseline and a useful compatibility reference, but it does not target Misstype's coordinate-aware phrase lattice. |
| Android | [Coco Zhuyin](https://play.google.com/store/apps/details?id=com.cocozq.inputmethod.zhuyin) | Offline/privacy-oriented Zhuyin, physical-keyboard phones, custom dictionaries, themes, and fast candidate selection. | It serves physical-keyboard and conventional soft-keyboard users well; the split-surface experiment remains distinct. |
| Android | [Zhuyin Simplified](https://play.google.com/store/apps/details?id=io.metamystic.zhuyin) | Offline Zhuyin-to-Simplified keyboard with dynamic layouts, candidates, and no-data-collection positioning. | It demonstrates a focused product can coexist with Gboard, but its goal is output conversion rather than input uncertainty. |

## Platform constraints

iOS custom keyboards run as extensions. Apple documents that they are replaced
by the system keyboard for secure and phone-pad fields, can be rejected by an
app, cannot select text directly, and have a separate-process memory limit. A
keyboard without Full Access cannot use network or shared-container storage;
Full Access expands capability but raises the trust and review burden. See
[Apple's custom keyboard guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html),
[open-access guidance](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard),
and [custom-keyboard interaction guidance](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards).

Android exposes the IME through `InputConnection` and `InputMethodManager`,
which are designed for a software keyboard to send composing text, commits,
deletions, and editor actions to the host. See the Android
[InputConnection API](https://developer.android.com/reference/android/view/inputmethod/InputConnection)
and [InputMethodManager API](https://developer.android.com/reference/android/view/inputmethod/InputMethodManager).

## Decision

Build **Android first**, as a private sideload/F-Droid-style prototype. This is
the shorter path to testing the product hypothesis because Android gives the
project a first-class IME service boundary, supports raw touch capture in the
keyboard view, and permits rapid installation across emulator/device and
physical-keyboard configurations. The existing Android products are strong,
but their strengths make the experiment measurable: compare against Gboard,
Chaozhuyin, and Guileless Bopomofo on the same phrases and tap traces.

Defer iOS until Android shows a measurable gain in tap-spread tolerance or
reduced candidate interruption. iOS remains worthwhile, especially for Taiwan
users, but its custom-keyboard restrictions and already strong products make
it a higher-cost validation target. Keep the iOS adapter in the architecture
plan so the Zig session and trace fixtures stay platform-neutral.

## Smallest falsifiable experiment

Implement Android capture-only first: two split surfaces, raw trace export, and
replay into the existing Zig touch lattice. Compare against a conventional
Zhuyin keyboard at matched phrases and measure tap spread, top-1/top-8 recall,
candidate interruptions, and per-key latency. If the touch surface does not
beat the conventional baseline at observed human spread, stop before building
the full Android IME or any iOS extension.
