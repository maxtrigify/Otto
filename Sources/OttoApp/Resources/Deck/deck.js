// Otto deck engine. Modes: "present" (keys/clicks step through), "edit" (one slide, text is
// editable in place, changes go back to Otto), "static" (final frame, for thumbnails/export).
(function () {
  "use strict";
  var W = 1280, H = 720;
  var config = window.OTTO_DECK || { mode: "present", index: 0 };
  var stage, slides = [], current = -1;
  var post = function (message) {
    try { window.webkit.messageHandlers.otto.postMessage(message); } catch (e) {}
  };
  var ease = function (t) { return 1 - Math.pow(1 - t, 3); };
  var tween = function (duration, frame) {
    if (config.mode !== "present") { frame(1); return; }
    var start = null;
    var step = function (now) {
      if (start === null) start = now;
      var t = Math.min(1, (now - start) / duration);
      frame(ease(t));
      if (t < 1) requestAnimationFrame(step);
    };
    frame(0);
    requestAnimationFrame(step);
  };
  var json = function (value, fallback) {
    try { var parsed = JSON.parse(value); return Array.isArray(parsed) ? parsed : fallback; }
    catch (e) { return fallback; }
  };
  var css = function (name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  };
  var format = function (value, el) {
    var decimals = parseInt(el.getAttribute("data-decimals") || "", 10);
    if (isNaN(decimals)) decimals = Math.abs(value) < 10 && value % 1 !== 0 ? 1 : 0;
    var text = Number(value).toLocaleString("en-US", {
      minimumFractionDigits: decimals, maximumFractionDigits: decimals });
    return (el.getAttribute("data-prefix") || "") + text + (el.getAttribute("data-suffix") || "");
  };
  var svg = function (tag, attrs, parent) {
    var node = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (var key in attrs) node.setAttribute(key, attrs[key]);
    if (parent) parent.appendChild(node);
    return node;
  };

  // Charts: <div class="chart" data-type="bar|hbar|line|area|donut" data-labels='[..]'
  // data-values='[..]' data-values2='[..]' data-names='["A","B"]' data-prefix data-suffix>
  function drawChart(el, t) {
    var old = el.querySelector("svg[data-gen]");
    if (old) old.remove();
    var type = el.getAttribute("data-type") || "bar";
    var labels = json(el.getAttribute("data-labels"), []);
    var series = [json(el.getAttribute("data-values"), [])];
    var second = json(el.getAttribute("data-values2"), null);
    if (second) series.push(second);
    var colors = [css("--accent") || "#ff7a45", css("--accent2") || "#ffb86b"];
    var w = el.clientWidth || 600, h = el.clientHeight || 360;
    var root = svg("svg", { viewBox: "0 0 " + w + " " + h, "data-gen": "1" }, el);
    var defs = svg("defs", {}, root);
    colors.forEach(function (color, i) {
      var g = svg("linearGradient", { id: "g" + i + el.dataset.uid, x1: 0, y1: 0, x2: 0, y2: 1 }, defs);
      svg("stop", { offset: "0%", "stop-color": color }, g);
      svg("stop", { offset: "100%", "stop-color": color, "stop-opacity": type === "area" ? 0 : 0.55 }, g);
    });
    var values = series.reduce(function (a, s) { return a.concat(s); }, []);
    var max = Math.max.apply(null, values.concat([0])) || 1;
    var min = Math.min.apply(null, values.concat([0]));
    if (type === "donut") {
      var data = series[0], total = data.reduce(function (a, b) { return a + b; }, 0) || 1;
      var r = Math.min(w * 0.42, h) / 2 - 14, cx = Math.min(w * 0.42, h) / 2, cy = h / 2;
      var C = 2 * Math.PI * r, offset = 0;
      var palette = [colors[0], colors[1], css("--text"), css("--muted"), "#7c8cff", "#5fe39a"];
      svg("circle", { cx: cx, cy: cy, r: r, fill: "none", stroke: css("--surface") || "#222", "stroke-width": 34 }, root);
      data.forEach(function (v, i) {
        var len = (v / total) * C * t;
        svg("circle", { cx: cx, cy: cy, r: r, fill: "none", stroke: palette[i % palette.length],
          "stroke-width": 34, "stroke-dasharray": Math.max(0, len - 3) + " " + C,
          "stroke-dashoffset": -offset * t, transform: "rotate(-90 " + cx + " " + cy + ")",
          "stroke-linecap": "butt" }, root);
        offset += (v / total) * C;
        var ly = 40 + i * 44;
        svg("rect", { x: cx * 2 + 40, y: ly - 14, width: 16, height: 16, rx: 4, fill: palette[i % palette.length] }, root);
        var label = svg("text", { x: cx * 2 + 68, y: ly, "class": "val" }, root);
        label.textContent = (labels[i] || "") + "  " + Math.round((v / total) * 100) + "%";
      });
      var center = svg("text", { x: cx, y: cy + 12, "text-anchor": "middle", "class": "val",
        style: "font-size:34px;font-weight:760" }, root);
      center.textContent = format(total * t, el);
      return;
    }
    var padL = 56, padB = 40, padT = 26, padR = 12;
    var plotW = w - padL - padR, plotH = h - padB - padT;
    // Round the axis to friendly steps (1, 2, 2.5, 5 × 10ⁿ).
    var raw = (max - Math.min(0, min)) / 4 || 1, mag = Math.pow(10, Math.floor(Math.log10(raw)));
    var unit = raw / mag, step = (unit <= 1 ? 1 : unit <= 2 ? 2 : unit <= 2.5 ? 2.5 : unit <= 5 ? 5 : 10) * mag;
    var lo = Math.floor(Math.min(0, min) / step) * step, hi = Math.ceil(max / step) * step;
    var y = function (v) { return padT + plotH - ((v - lo) / (hi - lo || 1)) * plotH; };
    var grid = svg("g", { "class": "grid" }, root);
    for (var gi = 0; lo + gi * step <= hi + step / 2; gi++) {
      var gv = lo + gi * step, gy = y(gv);
      svg("line", { x1: padL, x2: w - padR, y1: gy, y2: gy }, grid);
      var tick = svg("text", { x: padL - 10, y: gy + 5, "text-anchor": "end" }, root);
      tick.textContent = format(gv, el);
    }
    if (type === "hbar") {
      var rowH = plotH / Math.max(1, labels.length);
      series[0].forEach(function (v, i) {
        var bw = ((v - 0) / max) * (plotW - 120) * t, by = padT + i * rowH + rowH * 0.18;
        svg("rect", { x: padL + 110, y: by, width: Math.max(0, bw), height: rowH * 0.64, rx: 8,
          fill: colors[0] }, root);
        var name = svg("text", { x: padL + 100, y: by + rowH * 0.42, "text-anchor": "end" }, root);
        name.textContent = labels[i] || "";
        var val = svg("text", { x: padL + 118 + bw, y: by + rowH * 0.42, "class": "val" }, root);
        val.textContent = format(v * t, el);
      });
      return;
    }
    var n = Math.max(1, labels.length || series[0].length);
    var slot = plotW / n;
    labels.forEach(function (label, i) {
      var tx = svg("text", { x: padL + slot * (i + 0.5), y: h - 12, "text-anchor": "middle" }, root);
      tx.textContent = label;
    });
    if (type === "bar") {
      var groupW = slot * 0.62, barW = groupW / series.length;
      series.forEach(function (data, s) {
        data.forEach(function (v, i) {
          var top = y(v * t), base = y(0);
          var x = padL + slot * i + (slot - groupW) / 2 + barW * s;
          svg("rect", { x: x + 3, y: Math.min(top, base), width: Math.max(2, barW - 6),
            height: Math.abs(base - top), rx: 10, fill: "url(#g" + s + el.dataset.uid + ")" }, root);
          if (series.length === 1) {
            var vt = svg("text", { x: x + barW / 2, y: Math.min(top, base) - 10, "text-anchor": "middle", "class": "val" }, root);
            vt.textContent = format(v * t, el);
          }
        });
      });
    } else {
      series.forEach(function (data, s) {
        var points = data.map(function (v, i) { return [padL + slot * (i + 0.5), y(v)]; });
        var d = points.map(function (p, i) {
          if (i === 0) return "M" + p[0] + "," + p[1];
          var prev = points[i - 1], mx = (prev[0] + p[0]) / 2;
          return "C" + mx + "," + prev[1] + " " + mx + "," + p[1] + " " + p[0] + "," + p[1];
        }).join(" ");
        if (type === "area" && points.length) {
          svg("path", { d: d + " L" + points[points.length - 1][0] + "," + y(lo) +
            " L" + points[0][0] + "," + y(lo) + " Z", fill: "url(#g" + s + el.dataset.uid + ")",
            opacity: 0.55 * t }, root);
        }
        var path = svg("path", { d: d, "class": "line", stroke: colors[s] }, root);
        var length = path.getTotalLength ? path.getTotalLength() : 2000;
        path.setAttribute("stroke-dasharray", length);
        path.setAttribute("stroke-dashoffset", length * (1 - t));
        points.forEach(function (p, i) {
          if (t < (i + 1) / points.length) return;
          svg("circle", { cx: p[0], cy: p[1], r: 6, fill: css("--bg") || "#000", stroke: colors[s], "stroke-width": 3 }, root);
        });
        if (series.length === 1 && points.length) {
          var last = points[points.length - 1];
          var lv = svg("text", { x: last[0], y: last[1] - 16, "text-anchor": "middle", "class": "val" }, root);
          lv.textContent = format(data[data.length - 1] * t, el);
        }
      });
    }
    var names = json(el.getAttribute("data-names"), null);
    if (names && !el.querySelector(".legend")) {
      var legend = document.createElement("div");
      legend.className = "legend";
      legend.setAttribute("data-gen", "1");
      legend.innerHTML = names.map(function (name, i) {
        return '<span><i style="background:' + colors[i % 2] + '"></i>' + String(name).replace(/</g, "&lt;") + "</span>";
      }).join("");
      el.parentNode.insertBefore(legend, el.nextSibling);
    }
  }

  // An isometric cube drawn as shaded faces, so it reads as 3D in every renderer.
  function drawCube(el) {
    if (el.querySelector("svg[data-gen]")) return;
    var root = svg("svg", { viewBox: "0 0 220 240", "data-gen": "1" }, el);
    var defs = svg("defs", {}, root);
    var accent = css("--accent") || "#ff7a45", accent2 = css("--accent2") || "#ffb86b";
    [["t", accent2, accent, 1], ["l", accent, accent2, 0.78], ["r", accent, accent, 0.58]].forEach(function (f) {
      var g = svg("linearGradient", { id: "cube-" + f[0], x1: 0, y1: 0, x2: 1, y2: 1 }, defs);
      svg("stop", { offset: "0%", "stop-color": f[1] }, g);
      svg("stop", { offset: "100%", "stop-color": f[2] }, g);
    });
    var faces = [
      ["t", "110,20 200,72 110,124 20,72", 1],
      ["l", "20,72 110,124 110,228 20,176", 0.78],
      ["r", "200,72 110,124 110,228 200,176", 0.58],
    ];
    faces.forEach(function (f) {
      svg("polygon", { points: f[1], fill: "url(#cube-" + f[0] + ")" }, root);
      // Side faces sit in shade so the form reads at a glance.
      if (f[2] < 1) svg("polygon", { points: f[1], fill: "#000", opacity: (1 - f[2]) * 1.1 }, root);
      svg("polygon", { points: f[1], fill: "none", stroke: "rgba(255,255,255,.35)", "stroke-width": 1.5,
        "stroke-linejoin": "round" }, root);
    });
    svg("polyline", { points: "20,72 110,124 200,72", fill: "none", stroke: "rgba(255,255,255,.55)", "stroke-width": 2 }, root);
    svg("line", { x1: 110, y1: 124, x2: 110, y2: 228, stroke: "rgba(255,255,255,.3)", "stroke-width": 1.5 }, root);
  }

  function animate(slide) {
    slide.querySelectorAll(".cube").forEach(drawCube);
    slide.querySelectorAll(".chart").forEach(function (el) {
      tween(1300, function (t) { drawChart(el, t); });
    });
    slide.querySelectorAll("[data-count]").forEach(function (el) {
      var target = parseFloat(el.getAttribute("data-count")) || 0;
      tween(1500, function (t) { el.textContent = format(target * t, el); });
    });
    slide.querySelectorAll(".progress[data-value]").forEach(function (el) {
      var bar = el.querySelector("i") || el.appendChild(document.createElement("i"));
      bar.style.width = Math.min(100, parseFloat(el.getAttribute("data-value")) || 0) + "%";
    });
    // Delays and staggers.
    slide.querySelectorAll("[data-delay]").forEach(function (el) {
      el.style.transitionDelay = (parseInt(el.getAttribute("data-delay"), 10) || 0) + "ms";
    });
    slide.querySelectorAll(".stagger").forEach(function (group) {
      Array.prototype.forEach.call(group.children, function (child, i) {
        child.style.transitionDelay = (120 + i * 110) + "ms";
      });
    });
  }

  function go(index) {
    if (!slides.length) return;
    index = Math.max(0, Math.min(slides.length - 1, index));
    if (index === current) return;
    current = index;
    slides.forEach(function (slide, i) {
      slide.classList.toggle("active", i === index);
      slide.classList.toggle("before", i < index);
    });
    animate(slides[index]);
    var bar = document.querySelector(".progressbar");
    if (bar) bar.style.width = ((index + 1) / slides.length) * 100 + "%";
    var counter = document.querySelector(".counter");
    if (counter) counter.textContent = (index + 1) + " / " + slides.length;
    post({ type: "slide", index: index });
  }

  function fit() {
    var scale = Math.min(window.innerWidth / W, window.innerHeight / H) || 1;
    stage.style.transform = "translate(-50%, -50%) scale(" + scale + ")";
  }

  // In edit mode text can be changed in place; the cleaned slide HTML goes back to Otto.
  var editables = "h1,h2,h3,p,li,.kicker,.lead,.label,.pill,.badge,.quote,.cite,td,th,.small";
  function cleanHTML(slide) {
    var copy = slide.cloneNode(true);
    copy.querySelectorAll("[data-gen]").forEach(function (n) { n.remove(); });
    copy.querySelectorAll("[contenteditable]").forEach(function (n) {
      n.removeAttribute("contenteditable"); n.removeAttribute("spellcheck");
    });
    copy.querySelectorAll("[style]").forEach(function (n) {
      n.style.transitionDelay = "";
      if (!n.getAttribute("style")) n.removeAttribute("style");
    });
    copy.querySelectorAll(".progress > i").forEach(function (n) { n.removeAttribute("style"); });
    return copy.innerHTML.trim();
  }
  function enableEditing(slide) {
    slide.querySelectorAll(editables).forEach(function (el) {
      if (el.closest(".chart") || el.hasAttribute("data-count")) return;
      el.setAttribute("contenteditable", "true");
      el.setAttribute("spellcheck", "true");
    });
    var timer = null;
    slide.addEventListener("input", function () {
      clearTimeout(timer);
      timer = setTimeout(function () { post({ type: "edit", html: cleanHTML(slide) }); }, 450);
    });
    // Tell Otto when text on the slide has the caret, so arrow keys stay with the text.
    slide.addEventListener("focusin", function () { post({ type: "editing", active: true }); });
    slide.addEventListener("focusout", function () { post({ type: "editing", active: false }); });
    document.addEventListener("selectionchange", function () {
      var text = String(window.getSelection() || "").trim();
      post({ type: "selection", text: text });
    });
  }

  function tilt() {
    document.querySelectorAll(".tilt").forEach(function (el) {
      el.addEventListener("pointermove", function (e) {
        var r = el.getBoundingClientRect();
        var x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
        el.style.transform = "rotateY(" + x * 16 + "deg) rotateX(" + -y * 16 + "deg) translateZ(10px)";
      });
      el.addEventListener("pointerleave", function () { el.style.transform = ""; });
    });
  }

  function start() {
    stage = document.querySelector(".stage");
    slides = Array.prototype.slice.call(document.querySelectorAll(".slide"));
    slides.forEach(function (s, i) {
      s.querySelectorAll(".chart").forEach(function (c, j) { c.dataset.uid = i + "-" + j; });
    });
    document.body.classList.add(config.mode === "present" ? "present" : "static");
    if (config.mode === "edit") document.body.classList.add("edit");
    fit();
    window.addEventListener("resize", fit);
    if (window.ResizeObserver) new ResizeObserver(fit).observe(document.documentElement);
    go(config.index || 0);
    if (config.mode === "edit" && slides[0]) enableEditing(slides[0]);
    if (config.mode === "present") {
      tilt();
      document.addEventListener("keydown", function (e) {
        if (["ArrowRight", "ArrowDown", "PageDown", " ", "Enter"].indexOf(e.key) >= 0) { go(current + 1); e.preventDefault(); }
        else if (["ArrowLeft", "ArrowUp", "PageUp", "Backspace"].indexOf(e.key) >= 0) { go(current - 1); e.preventDefault(); }
        else if (e.key === "Home") go(0);
        else if (e.key === "End") go(slides.length - 1);
        else if (e.key === "Escape") post({ type: "exit" });
      });
      document.addEventListener("click", function (e) {
        go(current + (e.clientX < window.innerWidth / 3 ? -1 : 1));
      });
    }
    window.OttoDeck = {
      go: go, count: slides.length,
      next: function () { go(current + 1); }, prev: function () { go(current - 1); },
      current: function () { return current; }
    };
    post({ type: "ready", count: slides.length });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
