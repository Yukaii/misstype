// Misstype for Obsidian: the Zhuyin decoder (misstype-wasm, offline) in every
// editor and text field. With a hardware keyboard it reads keys as the desktop
// IME does; on a phone it replaces the system keyboard with the on-screen
// Zhuyin keyboard of the site editor while a note is being edited.
import { Notice, Platform, Plugin, PluginSettingTab, Setting } from "obsidian";
import { EditorView, runScopeHandlers } from "@codemirror/view";
import { deleteCharBackward, insertNewlineAndIndent } from "@codemirror/commands";
import MisstypeWasm from "misstype-wasm";
import { enable } from "misstype-wasm/enable";
import { VirtualKeyboard, fromHardwareKeyboard } from "../../../site/editor/keyboard.js";
import { loadAssets } from "./assets.js";

const DEFAULTS = {
  enabled: true,
  keyboard: "auto", // on-screen keyboard: "auto" (phones and tablets without a keyboard) | "on" | "off"
  layout: "vertical",
  pageSize: 9,
  shiftToggle: true,
  userLearning: true,
};

const HW_KEYBOARD_KEY = "misstype-hardware-keyboard";
const editorOf = (el) => el?.closest?.(".cm-content") ?? null;

export default class MisstypePlugin extends Plugin {
  async onload() {
    this.settings = { ...DEFAULTS, ...(await this.loadData()) };
    this.ime = null; // MisstypeWasm, loaded once
    this.ms = null; // the enable() instance while on
    this.vkDismissed = false;
    this.hardwareKeyboardSeen = this.app.loadLocalStorage(HW_KEYBOARD_KEY) === "1";

    this.addSettingTab(new MisstypeSettingTab(this.app, this));
    this.addCommand({ id: "toggle", name: "Turn Misstype on or off", callback: () => this.setEnabled(!this.settings.enabled) });
    this.addCommand({ id: "toggle-english", name: "Switch between Chinese and English", callback: () => this.ms?.toggleEnglish() });
    this.addCommand({
      id: "toggle-keyboard",
      name: "Switch between the Zhuyin and the system keyboard",
      callback: () => {
        this.vkDismissed = !this.vkDismissed;
        this.applyKeyboard(true);
      },
    });
    if (!Platform.isMobile) {
      this.statusEl = this.addStatusBarItem();
      this.statusEl.addClass("mod-clickable", "misstype-status");
      this.statusEl.setAttribute("aria-label", "Misstype: Shift switches 中/英");
      this.registerDomEvent(this.statusEl, "click", () => this.ms?.toggleEnglish());
    }
    this.buildKeyboard();
    this.registerEvent(this.app.workspace.on("css-change", () => this.ms?.setTheme(this.theme())));
    this.app.workspace.onLayoutReady(() => { if (this.settings.enabled) this.start(); });
  }

  onunload() {
    this.stop();
    this.vkEl?.remove();
  }

  theme() {
    return document.body.classList.contains("theme-dark") ? "dark" : "light";
  }

  async start() {
    if (this.ms) return;
    try {
      this.ime ??= await MisstypeWasm.fromBytes(await loadAssets());
    } catch (error) {
      console.error("Misstype could not load", error);
      new Notice("Misstype could not load its decoder; see the developer console.");
      return;
    }
    // A vault-scoped key, so two vaults keep separate dictionaries and learning.
    const scope = `misstype-${this.app.appId ?? this.app.vault.getName()}`;
    const { layout, pageSize, shiftToggle, userLearning } = this.settings;
    this.ms = await enable({
      ime: this.ime,
      layout,
      theme: this.theme(),
      settings: { pageSize, shiftToggle, userLearning },
      storageKey: `${scope}-dictionary`,
      learningKey: `${scope}-learned`,
      insert: (el, text) => {
        const view = this.viewOf(el);
        if (!view) return false;
        view.dispatch({ ...view.state.replaceSelection(text), userEvent: "input.type", scrollIntoView: true });
        return true;
      },
      onChange: (state) => {
        this.vk?.setEnglish(state.english);
        this.statusEl?.setText(state.english ? "英" : "中");
      },
    });
    this.applyKeyboard();
  }

  stop() {
    this.ms?.destroy();
    this.ms = null;
    this.statusEl?.setText("");
    this.applyKeyboard();
  }

  async setEnabled(on) {
    this.settings.enabled = on;
    await this.saveSettings();
    if (on) await this.start();
    else this.stop();
  }

  async saveSettings() {
    await this.saveData(this.settings);
  }

  /** Re-applies decoder and window settings to a running instance. */
  applySettings() {
    if (!this.ms) return;
    for (const name of ["pageSize", "shiftToggle", "userLearning"]) this.ms.setSetting(name, this.settings[name]);
    this.ms.setLayout(this.settings.layout);
    this.applyKeyboard();
  }

  viewOf(el) {
    const content = editorOf(el);
    return content ? EditorView.findFromDOM(content) : null;
  }

  // ---- on-screen keyboard

  buildKeyboard() {
    this.vkEl = document.body.createDiv({ cls: "vk misstype-vk", attr: { "data-misstype-ui": "", hidden: "" } });
    this.vkEl.dataset.platform = Platform.isAndroidApp ? "android" : "ios";
    this.lastEditor = null; // the .cm-content the keys go to
    // Touching a key can blur the editor on iOS; do not treat that as leaving it.
    let touchUntil = 0;
    this.registerDomEvent(this.vkEl, "pointerdown", () => { touchUntil = performance.now() + 600; }, true);

    this.vk = new VirtualKeyboard(this.vkEl, {
      shift: (down) => {
        this.refocus();
        this.ms?.press("ShiftLeft", "Shift", down ? 1 : 0, !down);
      },
      press: (code, key, shift) => {
        this.refocus();
        if (!this.ms?.press(code, key, shift ? 1 : 0)) this.keyDefault(code, key, shift);
      },
    });

    this.registerDomEvent(document, "focusin", (e) => {
      const content = editorOf(e.target);
      if (!content) return;
      this.lastEditor = content;
      // As the system keyboard does: focusing again brings it back (not our own refocus below).
      if (!this.refocusing) this.vkDismissed = false;
      this.applyKeyboard();
    }, true);
    this.registerDomEvent(document, "focusout", () => {
      setTimeout(() => {
        if (editorOf(document.activeElement) || performance.now() < touchUntil) return;
        this.showKeyboard(false);
      }, 120);
    }, true);
    // A real keyboard turned up (an iPad with a Magic Keyboard): give the screen back.
    this.registerDomEvent(document, "keydown", (e) => {
      const content = editorOf(e.target);
      if (this.hardwareKeyboardSeen || !content || !fromHardwareKeyboard(e, content)) return;
      this.hardwareKeyboardSeen = true;
      this.app.saveLocalStorage(HW_KEYBOARD_KEY, "1");
      this.applyKeyboard();
    }, true);
    new ResizeObserver(() => document.body.style.setProperty("--misstype-vk-h", `${this.vkEl.offsetHeight}px`)).observe(this.vkEl);
    this.register(() => {
      document.body.style.removeProperty("--misstype-vk-h");
      document.body.removeClass("misstype-vk-on");
    });
  }

  keyboardWanted() {
    const mode = this.settings.keyboard;
    if (!this.ms || mode === "off") return false;
    return mode === "on" || (Platform.isMobile && !this.hardwareKeyboardSeen);
  }

  /** Shows our keyboard (and keeps the system one away) while an editor has focus. */
  applyKeyboard(refocus = false) {
    const wanted = this.keyboardWanted() && !this.vkDismissed;
    for (const el of document.querySelectorAll(".cm-content")) {
      if (wanted) el.setAttribute("inputmode", "none");
      else if (el.getAttribute("inputmode") === "none") el.removeAttribute("inputmode");
    }
    this.showKeyboard(wanted && !!editorOf(document.activeElement));
    // The system keyboard only reacts to inputmode on the next focus.
    if (refocus && this.lastEditor?.isConnected) {
      this.refocusing = true;
      this.lastEditor.blur();
      this.lastEditor.focus();
      this.refocusing = false;
    }
  }

  showKeyboard(on) {
    this.vkEl.toggleAttribute("hidden", !on);
    document.body.toggleClass("misstype-vk-on", on);
  }

  refocus() {
    if (this.lastEditor?.isConnected && !editorOf(document.activeElement)) this.lastEditor.focus();
  }

  /**
   * What the key would have done had the decoder not wanted it: the editor's
   * own keymap first (Enter continues a list, Backspace joins lines), then the
   * plain edit. Synthetic keydowns have no browser default of their own.
   */
  keyDefault(code, key, shift) {
    const view = this.viewOf(this.lastEditor);
    if (!view) return;
    const event = new KeyboardEvent("keydown", { code, key, shiftKey: shift, bubbles: true, cancelable: true });
    if (runScopeHandlers(view, event, "editor")) return;
    if (code === "Backspace") deleteCharBackward(view);
    else if (code === "Enter") insertNewlineAndIndent(view);
    else if (key.length === 1) view.dispatch({ ...view.state.replaceSelection(key), userEvent: "input.type", scrollIntoView: true });
  }
}

class MisstypeSettingTab extends PluginSettingTab {
  constructor(app, plugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display() {
    const { containerEl, plugin } = this;
    const { settings } = plugin;
    const save = async () => {
      await plugin.saveSettings();
      plugin.applySettings();
    };
    containerEl.empty();
    containerEl.createEl("p", {
      text: "Type Zhuyin (Dachen layout) and Misstype turns it into Chinese, repairing typos and missing tones. "
        + "A lone Shift tap switches between Chinese and English. Everything runs on this device.",
    });

    new Setting(containerEl).setName("Enable Misstype").addToggle((t) => t
      .setValue(settings.enabled)
      .onChange((on) => plugin.setEnabled(on)));

    new Setting(containerEl)
      .setName("On-screen keyboard")
      .setDesc("Automatic shows it on phones and tablets until a hardware keyboard is used.")
      .addDropdown((d) => d
        .addOptions({ auto: "Automatic", on: "Always", off: "Never" })
        .setValue(settings.keyboard)
        .onChange(async (value) => {
          settings.keyboard = value;
          if (value === "auto") {
            plugin.hardwareKeyboardSeen = false;
            plugin.app.saveLocalStorage(HW_KEYBOARD_KEY, null);
          }
          await save();
        }));

    new Setting(containerEl).setName("Candidate list").addDropdown((d) => d
      .addOptions({ vertical: "Vertical", horizontal: "Horizontal" })
      .setValue(settings.layout)
      .onChange(async (value) => { settings.layout = value; await save(); }));

    new Setting(containerEl).setName("Candidates per page").addSlider((s) => s
      .setLimits(4, 10, 1)
      .setValue(settings.pageSize)
      .setDynamicTooltip()
      .onChange(async (value) => { settings.pageSize = value; await save(); }));

    new Setting(containerEl).setName("Shift switches Chinese/English").addToggle((t) => t
      .setValue(settings.shiftToggle)
      .onChange(async (on) => { settings.shiftToggle = on; await save(); }));

    new Setting(containerEl)
      .setName("Learn from picks")
      .setDesc("Candidates you choose on purpose rank higher next time. Stored on this device for this vault.")
      .addToggle((t) => t
        .setValue(settings.userLearning)
        .onChange(async (on) => { settings.userLearning = on; await save(); }));
  }
}
