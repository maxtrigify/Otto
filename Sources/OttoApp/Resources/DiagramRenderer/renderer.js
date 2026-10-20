(() => {
  "use strict";

  const host = document.getElementById("diagram");
  const bridge = window.webkit?.messageHandlers?.ottoDiagram;
  let renderSequence = 0;
  let lastReportedHeight = 0;
  let interactive = false;
  let zoom = 1;
  let drag = null;

  function post(message) {
    bridge?.postMessage(message);
  }

  function decodeBase64UTF8(value) {
    const bytes = Uint8Array.from(atob(value), character => character.charCodeAt(0));
    return new TextDecoder().decode(bytes);
  }

  function decodeJSON(value) {
    return JSON.parse(decodeBase64UTF8(value));
  }

  function layoutDiagram() {
    const svg = host.querySelector("svg");
    if (!svg) return;
    const { width, height } = svg.viewBox.baseVal;
    if (!(width > 0 && height > 0)) return;
    const availableWidth = Math.max(1, document.documentElement.clientWidth - 24);
    const availableHeight = Math.max(1, document.documentElement.clientHeight - 24);
    const fit = Math.min(1, availableWidth / width, availableHeight / height);
    const factor = fit * (interactive ? zoom : 1);
    svg.style.width = `${width * factor}px`;
    svg.style.height = `${height * factor}px`;
    host.style.width = interactive ? `${Math.max(availableWidth + 24, width * factor + 24)}px` : "100%";
    host.style.height = interactive ? `${Math.max(availableHeight + 24, height * factor + 24)}px` : "100%";
    // Report the preferred height independently of the bounded viewport. This avoids
    // resize feedback loops and never scales small diagrams above their natural size.
    const preferredHeight = Math.ceil(Math.max(88, height * Math.min(1, availableWidth / width) + 24));
    if (preferredHeight !== lastReportedHeight) {
      lastReportedHeight = preferredHeight;
      post({ type: "height", value: preferredHeight });
    }
  }

  function configure(theme) {
    document.documentElement.style.setProperty("--otto-background", theme.background);
    document.documentElement.style.setProperty("--otto-foreground", theme.foreground);
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      suppressErrorRendering: true,
      maxTextSize: 65536,
      maxEdges: 500,
      theme: "base",
      themeVariables: {
        background: theme.background,
        primaryColor: theme.surface,
        primaryTextColor: theme.foreground,
        primaryBorderColor: theme.border,
        lineColor: theme.muted,
        secondaryColor: theme.raised,
        secondaryTextColor: theme.foreground,
        secondaryBorderColor: theme.border,
        tertiaryColor: theme.raised,
        tertiaryTextColor: theme.foreground,
        tertiaryBorderColor: theme.border,
        noteBkgColor: theme.raised,
        noteTextColor: theme.foreground,
        noteBorderColor: theme.border,
        clusterBkg: theme.raised,
        clusterBorder: theme.border,
        edgeLabelBackground: theme.background,
        fontFamily: "Avenir Next, sans-serif",
        fontSize: "16px"
      },
      flowchart: {
        htmlLabels: false,
        useMaxWidth: true,
        curve: "basis"
      }
    });
  }

  window.ottoDiagram = {
    setPresentation(isInteractive, nextZoom) {
      const changed = interactive !== isInteractive || zoom !== nextZoom;
      interactive = isInteractive;
      zoom = nextZoom;
      document.body.classList.toggle("interactive", interactive);
      layoutDiagram();
      if (changed && zoom === 1) document.body.scrollTo(0, 0);
    },
    async renderBase64(sourceValue, themeValue) {
      const sequence = ++renderSequence;
      try {
        const source = decodeBase64UTF8(sourceValue);
        const theme = decodeJSON(themeValue);
        configure(theme);
        const rendered = await mermaid.render(`otto-diagram-${sequence}`, source);
        if (sequence !== renderSequence) return;

        host.replaceChildren();
        const template = document.createElement("template");
        template.innerHTML = rendered.svg.trim();
        const svg = template.content.querySelector("svg");
        if (!svg) throw new Error("Mermaid did not produce an SVG diagram.");
        svg.removeAttribute("height");
        svg.removeAttribute("width");
        svg.setAttribute("role", "img");
        svg.setAttribute("aria-label", "Mermaid diagram");
        const naturalWidth = svg.viewBox.baseVal.width;
        if (naturalWidth > 0) svg.style.width = `${naturalWidth}px`;
        host.appendChild(svg);
        rendered.bindFunctions?.(host);
        requestAnimationFrame(() => {
          layoutDiagram();
          post({ type: "rendered", sequence });
        });
      } catch (error) {
        if (sequence !== renderSequence) return;
        host.replaceChildren();
        post({
          type: "error",
          sequence,
          message: String(error?.message || "The diagram could not be rendered.").slice(0, 300)
        });
      }
    }
  };

  new ResizeObserver(layoutDiagram).observe(document.documentElement);
  host.addEventListener("pointerdown", event => {
    if (!interactive || event.button !== 0) return;
    drag = { x: event.clientX, y: event.clientY, left: document.body.scrollLeft, top: document.body.scrollTop };
    host.setPointerCapture(event.pointerId);
    document.body.classList.add("dragging");
    event.preventDefault();
  });
  host.addEventListener("pointermove", event => {
    if (!drag) return;
    document.body.scrollTo(drag.left + drag.x - event.clientX, drag.top + drag.y - event.clientY);
  });
  function endDrag() { drag = null; document.body.classList.remove("dragging"); }
  host.addEventListener("pointerup", endDrag);
  host.addEventListener("pointercancel", endDrag);
  host.addEventListener("lostpointercapture", endDrag);
  window.addEventListener("error", event => {
    post({ type: "error", message: String(event.message || "The renderer failed.").slice(0, 300) });
  });
  window.addEventListener("unhandledrejection", event => {
    post({ type: "error", message: String(event.reason || "The renderer failed.").slice(0, 300) });
  });
  post({ type: "ready" });
})();
