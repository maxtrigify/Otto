'use strict';

// Line icons standing in for the SF Symbols the Mac app uses (same names where possible).
// 24-unit artboard, drawn with currentColor at a 1.6 stroke to match SF Symbols' regular weight.
const Icons = (() => {
  const paths = {
    magnifyingglass: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.4-4.4"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    tray: '<path d="M4 13.5 6.2 6.6A2 2 0 0 1 8.1 5.2h7.8a2 2 0 0 1 1.9 1.4L20 13.5"/><path d="M4 13.5h4.5l1.2 2.2h4.6l1.2-2.2H20V18a1.8 1.8 0 0 1-1.8 1.8H5.8A1.8 1.8 0 0 1 4 18z"/>',
    clock: '<circle cx="12" cy="12" r="8"/><path d="M12 7.5V12l3 2"/>',
    globe: '<circle cx="12" cy="12" r="8"/><path d="M4 12h16M12 4c2.4 2.5 3.4 5 3.4 8s-1 5.5-3.4 8c-2.4-2.5-3.4-5-3.4-8s1-5.5 3.4-8z"/>',
    'chart.bar': '<path d="M5 19V11M10 19V6M15 19v-6M20 19V9M3.5 19.5h17.5"/>',
    'doc.richtext': '<path d="M7 3.8h7l4 4V19a1.2 1.2 0 0 1-1.2 1.2H7A1.2 1.2 0 0 1 5.8 19V5A1.2 1.2 0 0 1 7 3.8z"/><path d="M14 3.8V8h4M8.8 12.5h6.4M8.8 15.5h4.4"/>',
    'doc.text': '<path d="M7 3.8h7l4 4V19a1.2 1.2 0 0 1-1.2 1.2H7A1.2 1.2 0 0 1 5.8 19V5A1.2 1.2 0 0 1 7 3.8z"/><path d="M14 3.8V8h4M8.8 11.5h6.4M8.8 14.5h6.4M8.8 17.2h3.6"/>',
    tablecells: '<rect x="4" y="5" width="16" height="14" rx="1.6"/><path d="M4 10h16M4 14.5h16M10 5v14"/>',
    rectangles: '<rect x="3.8" y="7.5" width="12.5" height="10" rx="1.4"/><path d="M8 7.5V5.6A1.1 1.1 0 0 1 9.1 4.5H19a1.1 1.1 0 0 1 1.1 1.1v8.3A1.1 1.1 0 0 1 19 15h-2.7"/>',
    brain: '<path d="M9.5 5.2A2.6 2.6 0 0 0 5 7a2.7 2.7 0 0 0-1 4.4 2.8 2.8 0 0 0 1.4 4.6A2.7 2.7 0 0 0 9.5 18.6M14.5 5.2A2.6 2.6 0 0 1 19 7a2.7 2.7 0 0 1 1 4.4 2.8 2.8 0 0 1-1.4 4.6 2.7 2.7 0 0 1-4.1 2.6M12 5v14"/>',
    terminal: '<rect x="3.8" y="5" width="16.4" height="14" rx="1.8"/><path d="m7.5 9.5 2.8 2.5-2.8 2.5M12.5 15h4"/>',
    gearshape: '<circle cx="12" cy="12" r="2.8"/><path d="M12 3.6v2.2M12 18.2v2.2M3.6 12h2.2M18.2 12h2.2M6.1 6.1l1.5 1.5M16.4 16.4l1.5 1.5M6.1 17.9l1.5-1.5M16.4 7.6l1.5-1.5"/><circle cx="12" cy="12" r="5.6"/>',
    paintpalette: '<path d="M12 4a8 8 0 1 0 0 16c1.3 0 1.8-.9 1.4-1.9-.4-1 .2-2.1 1.3-2.1H17a3.5 3.5 0 0 0 3.5-3.5C20.5 7.6 16.7 4 12 4z"/><circle cx="8" cy="11" r="1"/><circle cx="10.5" cy="7.8" r="1"/><circle cx="14.6" cy="8" r="1"/>',
    'sidebar.left': '<rect x="3.8" y="5" width="16.4" height="14" rx="2"/><path d="M9.5 5v14"/>',
    'chevron.down': '<path d="m7.5 10 4.5 4.5 4.5-4.5"/>',
    'chevron.left': '<path d="m14 6.5-5.5 5.5 5.5 5.5"/>',
    checkmark: '<path d="m5.5 12.5 4 4 9-9"/>',
    xmark: '<path d="M7 7l10 10M17 7 7 17"/>',
    pencil: '<path d="m15.5 5.5 3 3L9 18H6v-3z"/>',
    'text.bubble': '<path d="M5.5 5.5h13A1.5 1.5 0 0 1 20 7v8a1.5 1.5 0 0 1-1.5 1.5H11L7 19.5v-3H5.5A1.5 1.5 0 0 1 4 15V7a1.5 1.5 0 0 1 1.5-1.5z"/><path d="M8 10h8M8 13h5"/>',
    'arrow.turn': '<path d="M6 6v5.5A2.5 2.5 0 0 0 8.5 14H18M14.5 10.5 18 14l-3.5 3.5"/>',
    person: '<circle cx="12" cy="9" r="3.4"/><path d="M5.5 19.5a6.5 6.5 0 0 1 13 0"/>',
    'person.2': '<circle cx="9" cy="9" r="3"/><path d="M3.8 18.8a5.2 5.2 0 0 1 10.4 0"/><circle cx="16.5" cy="9.5" r="2.5"/><path d="M15.5 14.3a4.6 4.6 0 0 1 4.8 4.5"/>',
    sparkles: '<path d="M11 4.5c.6 3.2 2.3 4.9 5.5 5.5-3.2.6-4.9 2.3-5.5 5.5-.6-3.2-2.3-4.9-5.5-5.5 3.2-.6 4.9-2.3 5.5-5.5z"/><path d="M17.5 14.5c.3 1.6 1.1 2.4 2.7 2.7-1.6.3-2.4 1.1-2.7 2.7-.3-1.6-1.1-2.4-2.7-2.7 1.6-.3 2.4-1.1 2.7-2.7z"/>',
    'arrow.up': '<path d="M12 18.5V6M6.8 11.2 12 6l5.2 5.2"/>',
    circle: '<circle cx="12" cy="12" r="8"/>',
    'checkmark.circle': '<circle cx="12" cy="12" r="8"/><path d="m8.5 12.3 2.4 2.4 4.8-4.8"/>',
    'plus.circle': '<circle cx="12" cy="12" r="8"/><path d="M12 8.5v7M8.5 12h7"/>',
    'calendar': '<rect x="4" y="5.5" width="16" height="14" rx="2"/><path d="M4 10h16M8.5 3.8v3.4M15.5 3.8v3.4"/>',
    lock: '<rect x="6" y="11" width="12" height="9" rx="1.8"/><path d="M8.5 11V8.5a3.5 3.5 0 0 1 7 0V11"/>',
    folder: '<path d="M4 7.5A1.5 1.5 0 0 1 5.5 6h4l1.8 2h7.2A1.5 1.5 0 0 1 20 9.5v8A1.5 1.5 0 0 1 18.5 19h-13A1.5 1.5 0 0 1 4 17.5z"/>',
    'stop.fill': '<rect x="7" y="7" width="10" height="10" rx="1.5" fill="currentColor"/>',
    trash: '<path d="M5 7h14M10 4.5h4M7 7l.8 11.2A1.5 1.5 0 0 0 9.3 19.6h5.4a1.5 1.5 0 0 0 1.5-1.4L17 7"/>',
    paperclip: '<path d="m18 11.5-6.2 6.2a4 4 0 0 1-5.7-5.7l6.6-6.6a2.7 2.7 0 0 1 3.8 3.8l-6.5 6.5a1.3 1.3 0 0 1-1.9-1.9l5.8-5.8"/>',
  };

  /** An inline SVG element for `name` at `size` CSS pixels. */
  function icon(name, size = 15, className = '') {
    const wrapper = document.createElement('span');
    wrapper.className = `icon ${className}`.trim();
    wrapper.setAttribute('aria-hidden', 'true');
    wrapper.innerHTML = `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">${paths[name] || paths.circle}</svg>`;
    return wrapper;
  }

  /** Otto's bot face: a round body in the bot's colour with two eyes, like OttoFace on the Mac. */
  function face(name, size = 24) {
    const palettes = [
      ['#E8874A', '#F3B07E'],
      ['#5E9EDB', '#9CC4EE'],
      ['#D9645F', '#EE9F98'],
      ['#7FB069', '#B5D6A3'],
      ['#B884D8', '#D6B6EC'],
      ['#E0B34A', '#F0D38C'],
    ];
    let hash = 0;
    for (const character of name || '?') hash = (hash * 31 + character.charCodeAt(0)) >>> 0;
    const [body, cheek] = palettes[hash % palettes.length];
    const wrapper = document.createElement('span');
    wrapper.className = 'bot-face';
    wrapper.setAttribute('aria-hidden', 'true');
    wrapper.innerHTML = `<svg width="${size}" height="${size}" viewBox="0 0 32 32">
      <path d="M5 18c0-7 4.8-12 11-12s11 5 11 12-4.6 9.5-11 9.5S5 25 5 18z" fill="${body}"/>
      <ellipse cx="11.6" cy="16.6" rx="4.6" ry="4.9" fill="#fff"/>
      <ellipse cx="20.6" cy="16" rx="4.9" ry="5.2" fill="#fff"/>
      <circle cx="12.6" cy="17.4" r="2.1" fill="#1d1a1c"/>
      <circle cx="21.6" cy="16.8" r="2.3" fill="#1d1a1c"/>
      <path d="M22 6.5c1.2-2.2 3.4-2.6 4.2-1.4" stroke="${cheek}" stroke-width="1.8" fill="none" stroke-linecap="round"/>
    </svg>`;
    return wrapper;
  }

  return { icon, face };
})();
