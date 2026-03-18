(function () {
  const CHAT_PATH = "/chat/";

  function createButton() {
    const link = document.createElement("a");
    link.href = CHAT_PATH;
    link.textContent = "打开聊天工作台";
    link.setAttribute("aria-label", "打开聊天工作台");
    link.style.cssText = [
      "position:fixed",
      "right:24px",
      "bottom:24px",
      "z-index:9999",
      "display:inline-flex",
      "align-items:center",
      "justify-content:center",
      "min-width:156px",
      "height:48px",
      "padding:0 18px",
      "border-radius:999px",
      "background:linear-gradient(135deg,#0d7c66,#11a586)",
      "color:#f4fffc",
      "font:600 14px/1.1 'Segoe UI','PingFang SC','Microsoft YaHei',sans-serif",
      "text-decoration:none",
      "box-shadow:0 14px 34px rgba(13,124,102,.26)"
    ].join(";");
    return link;
  }

  function mount() {
    if (document.querySelector("[data-chat-workspace-entry]")) {
      return;
    }

    const link = createButton();
    link.dataset.chatWorkspaceEntry = "true";

    const headerActions = document.querySelector(".right.menu")
      || document.querySelector(".ui.menu .right.menu")
      || document.querySelector("header")
      || document.querySelector(".header")
      || document.body;

    if (headerActions && headerActions !== document.body) {
      link.style.position = "relative";
      link.style.right = "auto";
      link.style.bottom = "auto";
      link.style.marginLeft = "12px";
      link.style.minWidth = "132px";
      link.style.height = "40px";
      link.style.boxShadow = "0 10px 24px rgba(13,124,102,.18)";
    }

    headerActions.appendChild(link);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mount, { once: true });
  } else {
    mount();
  }
})();
