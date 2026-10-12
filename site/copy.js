// Handles .copy-btn clicks, copying code text to clipboard with visual feedback.
document.querySelectorAll(".copy-btn").forEach((btn) => {
  btn.addEventListener("click", async (e) => {
    e.preventDefault();
    e.stopPropagation();

    const card = btn.closest(".agent-card");
    const code = card?.querySelector("code");
    const text = code ? code.innerText.trim() : (btn.dataset.text || "");
    if (!text) return;

    try {
      await navigator.clipboard.writeText(text);
    } catch {
      // Fallback for older browsers or restricted permissions
      const textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.style.position = "fixed";
      textarea.style.opacity = "0";
      document.body.appendChild(textarea);
      textarea.select();
      try {
        document.execCommand("copy");
      } catch (err) {
        console.error("Fallback copy failed", err);
      }
      document.body.removeChild(textarea);
    }

    const label = btn.querySelector(".copy-label");
    const orig = btn.dataset.originalText || label?.textContent || "";
    btn.dataset.originalText = orig;

    if (label && btn.dataset.copied) {
      label.textContent = btn.dataset.copied;
    }
    btn.classList.add("copied");

    setTimeout(() => {
      if (label && orig) {
        label.textContent = orig;
      }
      btn.classList.remove("copied");
    }, 2000);
  });
});
