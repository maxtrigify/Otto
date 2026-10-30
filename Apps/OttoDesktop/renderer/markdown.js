'use strict';

// The light Markdown agents write, rendered safely: every character is escaped before any
// formatting is applied, and links only ever become https/http anchors opened externally.
const Markdown = (() => {
  const escape = (text) =>
    text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  function inline(text) {
    let html = escape(text);
    html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
    html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    html = html.replace(/(^|[^*])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>');
    html = html.replace(
      /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,
      (_match, label, url) => `<a href="${url}" data-external>${label}</a>`,
    );
    html = html.replace(
      /(^|[\s(])(https?:\/\/[^\s<)]+)/g,
      (_match, lead, url) => `${lead}<a href="${url}" data-external>${url}</a>`,
    );
    return html;
  }

  function render(source) {
    const lines = source.replace(/\r\n/g, '\n').split('\n');
    const out = [];
    let list = null;
    let paragraph = [];
    const flushParagraph = () => {
      if (paragraph.length) out.push(`<p>${paragraph.map(inline).join('<br>')}</p>`);
      paragraph = [];
    };
    const flushList = () => {
      if (list) out.push(`<${list.tag}>${list.items.map((item) => `<li>${inline(item)}</li>`).join('')}</${list.tag}>`);
      list = null;
    };
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      if (line.startsWith('```')) {
        flushParagraph();
        flushList();
        const code = [];
        index += 1;
        while (index < lines.length && !lines[index].startsWith('```')) code.push(lines[index++]);
        out.push(`<pre><code>${escape(code.join('\n'))}</code></pre>`);
        continue;
      }
      const heading = line.match(/^(#{1,3})\s+(.*)$/);
      const bullet = line.match(/^\s*[-*]\s+(.*)$/);
      const numbered = line.match(/^\s*\d+[.)]\s+(.*)$/);
      if (heading) {
        flushParagraph();
        flushList();
        out.push(`<h${heading[1].length + 2}>${inline(heading[2])}</h${heading[1].length + 2}>`);
      } else if (bullet || numbered) {
        flushParagraph();
        const tag = bullet ? 'ul' : 'ol';
        if (list && list.tag !== tag) flushList();
        if (!list) list = { tag, items: [] };
        list.items.push((bullet || numbered)[1]);
      } else if (!line.trim()) {
        flushParagraph();
        flushList();
      } else {
        flushList();
        paragraph.push(line);
      }
    }
    flushParagraph();
    flushList();
    return out.join('');
  }

  return { render, escape };
})();
