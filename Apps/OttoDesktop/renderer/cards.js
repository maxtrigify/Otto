'use strict';

// Live cards (HomeCard) as the Mac's HomeCardsView draws them: lists, big numbers with their
// change and a sparkline, short notes, and line or bar charts, on smoked glass with light text
// on every theme. Used by Home and Dashboards.
const Cards = (() => {
  const SVG = 'http://www.w3.org/2000/svg';
  /** HomeCardColor.swatch on the Mac. */
  const swatches = {
    green: '#3ddb96',
    blue: '#5ca8ff',
    purple: '#a88cfa',
    pink: '#f573b5',
    orange: '#fa913d',
    yellow: '#facc14',
    red: '#f87070',
    gray: '#a1a1ab',
  };
  /** Dashboard.CardStyle.smoke on the Mac. */
  const smoke = { frosted: 0.22, smoked: 0.5, solid: 0.86 };

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  };
  const svg = (tag, attributes = {}) => {
    const node = document.createElementNS(SVG, tag);
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
    return node;
  };

  /** HomeCardRow.number: "12,480", "1.2k", "$3.4M" and "85%" all count. */
  function number(text) {
    if (text === undefined || text === null) return null;
    let raw = String(text).trim().toLowerCase().replace(/[,$£€%\s]/g, '');
    if (!raw) return null;
    let scale = 1;
    const suffix = raw.slice(-1);
    if (suffix === 'k') scale = 1e3;
    else if (suffix === 'm') scale = 1e6;
    else if (suffix === 'b') scale = 1e9;
    if (scale !== 1) raw = raw.slice(0, -1);
    const value = Number(raw);
    return Number.isFinite(value) ? value * scale : null;
  }

  const plain = (value) => (Math.round(value) === value ? String(value) : value.toFixed(2));
  const signed = (value) => `${value > 0 ? '+' : ''}${Math.abs(value) >= 1000 ? value.toLocaleString() : plain(value)}`;

  /** 8900 → "8.9k", 5.9 → "5.9", 12 → "12". */
  function axisLabel(value) {
    const short = (number) => String(Math.round(number * 10) / 10);
    if (Math.abs(value) >= 1e6) return `${short(value / 1e6)}M`;
    if (Math.abs(value) >= 1e3) return `${short(value / 1e3)}k`;
    return short(value);
  }

  function when(value) {
    const minutes = Math.round((Date.now() - new Date(value).getTime()) / 60000);
    if (!Number.isFinite(minutes)) return '';
    if (minutes < 1) return 'now';
    if (minutes < 60) return `${minutes} min. ago`;
    if (minutes < 60 * 24) return `${Math.round(minutes / 60)} hr. ago`;
    return `${Math.round(minutes / (60 * 24))} days ago`;
  }

  function sparkline(values, color) {
    const width = 44;
    const height = 14;
    const low = Math.min(...values);
    const span = Math.max(...values) - low || 1;
    const points = values.map((value, index) => `${((index / (values.length - 1)) * width).toFixed(1)},${(height - ((value - low) / span) * height).toFixed(1)}`);
    const graphic = svg('svg', { width, height, viewBox: `0 0 ${width} ${height}`, class: 'sparkline' });
    graphic.append(svg('polyline', { points: points.join(' '), fill: 'none', stroke: color, 'stroke-width': 1.2, 'stroke-linejoin': 'round' }));
    return graphic;
  }

  function metrics(rows, tint) {
    const grid = el('div', 'metric-grid');
    for (const row of rows.slice(0, 9)) {
      const cell = el('div', 'metric');
      cell.append(el('div', 'micro', row.label.toUpperCase()), el('div', 'metric-value', row.value ?? '—'));
      const line = el('div', 'metric-line');
      const history = row.history || [];
      const current = number(row.value);
      const delta = current !== null && history.length >= 2 ? current - history[history.length - 2] : null;
      if (delta) line.append(el('span', `metric-delta ${delta > 0 ? 'up' : 'down'}`, signed(delta)));
      else if (row.detail) line.append(el('span', 'metric-detail', row.detail));
      if (history.length >= 3) line.append(sparkline(history, tint || 'rgba(245, 240, 232, 0.5)'));
      cell.append(line);
      grid.append(cell);
    }
    return grid;
  }

  /** Line and bar charts plot each row's value in order; labels run along the bottom. */
  function chart(card, tint) {
    const points = card.rows.map((row) => ({ label: row.label, value: number(row.value) })).filter((point) => point.value !== null);
    const width = 600;
    const height = 170;
    const left = 40;
    const bottom = 20;
    const plotWidth = width - left - 6;
    const plotHeight = height - bottom - 8;
    let low = Math.min(...points.map((point) => point.value));
    let high = Math.max(...points.map((point) => point.value));
    // Trends read better when the axis hugs the data; bars start at zero.
    if (card.style === 'bar') low = Math.min(0, low);
    else low -= Math.max((high - low) * 0.15, Math.abs(low) * 0.001);
    if (high === low) high = low + 1;
    const y = (value) => 8 + plotHeight - ((value - low) / (high - low)) * plotHeight;
    const step = plotWidth / Math.max(points.length, 1);
    const x = (index) => left + step * index + step / 2;

    const graphic = svg('svg', { viewBox: `0 0 ${width} ${height}`, class: 'card-chart', role: 'img', preserveAspectRatio: 'none' });
    graphic.setAttribute('aria-label', points.map((point) => `${point.label} ${plain(point.value)}`).join(', '));
    for (let tick = 0; tick <= 3; tick += 1) {
      const value = low + ((high - low) * tick) / 3;
      graphic.append(svg('line', { x1: left, x2: width, y1: y(value), y2: y(value), class: 'grid' }));
      const label = svg('text', { x: left - 6, y: y(value) + 3, class: 'axis', 'text-anchor': 'end' });
      label.textContent = axisLabel(value);
      graphic.append(label);
    }
    const every = Math.ceil(points.length / 8);
    points.forEach((point, index) => {
      if (index % every) return;
      const label = svg('text', { x: x(index), y: height - 4, class: 'axis', 'text-anchor': 'middle' });
      label.textContent = point.label.length > 10 ? `${point.label.slice(0, 9)}…` : point.label;
      graphic.append(label);
    });

    if (card.style === 'bar') {
      const barWidth = Math.min(step * 0.62, 48);
      points.forEach((point, index) => {
        const top = y(Math.max(point.value, 0));
        const base = y(Math.min(point.value, 0) || low);
        graphic.append(svg('rect', { x: x(index) - barWidth / 2, y: top, width: barWidth, height: Math.max(1, base - top), rx: 4, fill: tint, class: 'bar' }));
      });
    } else {
      const id = `fade-${card.id}`;
      const defs = svg('defs');
      const gradient = svg('linearGradient', { id, x1: 0, x2: 0, y1: 0, y2: 1 });
      gradient.append(svg('stop', { offset: '0%', 'stop-color': tint, 'stop-opacity': 0.28 }), svg('stop', { offset: '100%', 'stop-color': tint, 'stop-opacity': 0.02 }));
      defs.append(gradient);
      graphic.append(defs);
      const line = points.map((point, index) => `${index ? 'L' : 'M'}${x(index).toFixed(1)},${y(point.value).toFixed(1)}`).join(' ');
      const floor = y(low);
      graphic.append(svg('path', { d: `${line} L${x(points.length - 1)},${floor} L${x(0)},${floor} Z`, fill: `url(#${id})` }));
      graphic.append(svg('path', { d: line, fill: 'none', stroke: tint, 'stroke-width': 2, 'stroke-linejoin': 'round', 'vector-effect': 'non-scaling-stroke' }));
    }
    return graphic;
  }

  function list(rows) {
    const box = el('div', 'card-list');
    for (const row of rows.slice(0, 12)) {
      const item = el(row.url ? 'a' : 'div', 'card-list-row');
      if (row.url) {
        item.href = row.url;
        item.target = '_blank';
        item.rel = 'noreferrer';
        item.title = row.url;
      }
      const text = el('div', 'card-list-text');
      text.append(el('span', 'card-list-label', row.url ? `${row.label} ↗` : row.label));
      if (row.detail) text.append(el('span', 'card-list-detail', row.detail));
      item.append(text);
      if (row.value) item.append(el('span', 'card-list-value', row.value));
      box.append(item);
    }
    if (rows.length > 12) box.append(el('div', 'micro', `+${rows.length - 12} more`));
    return box;
  }

  /**
   * One card. `options`: accent (the page's colour), cardStyle (frosted/smoked/solid),
   * automationName, editing, and onEdit(change) / onMove(offset) / onRemove() for edit mode.
   */
  function render(card, options = {}) {
    const color = card.color || options.accent;
    const tint = color ? swatches[color] : 'rgb(var(--card-signal-rgb))';
    const box = el('article', `data-card width-${card.width || 'regular'}`);
    box.dataset.id = card.id;
    box.style.setProperty('--smoke', String(smoke[options.cardStyle] ?? smoke.smoked));
    if (options.editing) box.classList.add('editing');

    const header = el('div', 'data-card-header');
    header.append(el('h3', '', card.title));
    box.append(header);

    const content = el('div', 'data-card-content');
    const empty = !card.rows?.length && !card.text?.trim();
    if (empty) {
      content.append(el('p', 'card-muted', options.automationName ? 'Nothing yet. It fills in on the next run.' : 'Nothing here yet.'));
    } else {
      const numeric = card.rows.some((row) => number(row.value) !== null);
      if (card.style === 'metrics' && card.rows.length) content.append(metrics(card.rows, color ? tint : null));
      else if ((card.style === 'line' || card.style === 'bar') && numeric) content.append(chart(card, tint));
      else if (card.rows.length) content.append(list(card.rows));
      if (card.text) {
        const text = el('div', 'card-text');
        text.innerHTML = Markdown.render(card.text);
        content.append(text);
      }
    }
    box.append(content);

    if (options.editing) {
      box.append(editBar(card, options));
      return box;
    }
    const footer = el('div', 'data-card-footer');
    const by = options.automationName || card.updatedBy;
    footer.append(el('span', 'micro grow', [`Updated ${when(card.updatedAt)}`, by].filter(Boolean).join(' · ').toUpperCase()));
    if (card.source) {
      const how = el('button', 'micro how', 'HOW THIS WAS MADE');
      const source = el('pre', 'card-source', card.source);
      source.hidden = true;
      how.addEventListener('click', () => {
        source.hidden = !source.hidden;
        how.textContent = source.hidden ? 'HOW THIS WAS MADE' : 'HIDE';
      });
      footer.append(how);
      box.append(footer, source);
    } else {
      box.append(footer);
    }
    return box;
  }

  function editBar(card, options) {
    const bar = el('div', 'card-edit-bar');
    const sizes = el('div', 'segmented');
    for (const [value, label] of [['regular', 'Regular'], ['wide', 'Wide'], ['full', 'Full']]) {
      const button = el('button', (card.width || 'regular') === value ? 'active' : '', label);
      button.addEventListener('click', () => options.onEdit?.({ width: value }));
      sizes.append(button);
    }
    const colors = el('div', 'swatches');
    const none = el('button', `swatch none ${card.color ? '' : 'active'}`.trim());
    none.title = 'Page colour';
    none.addEventListener('click', () => options.onEdit?.({ color: '' }));
    colors.append(none);
    for (const [name, value] of Object.entries(swatches)) {
      const swatch = el('button', `swatch ${card.color === name ? 'active' : ''}`.trim());
      swatch.style.background = value;
      swatch.title = name[0].toUpperCase() + name.slice(1);
      swatch.addEventListener('click', () => options.onEdit?.({ color: name }));
      colors.append(swatch);
    }
    const move = el('div', 'card-move');
    for (const [offset, label, title] of [[-1, '←', 'Move earlier'], [1, '→', 'Move later']]) {
      const button = el('button', 'tiny', label);
      button.title = title;
      button.addEventListener('click', () => options.onMove?.(offset));
      move.append(button);
    }
    const remove = el('button', 'tiny', '');
    remove.append(Icons.icon('trash', 13));
    remove.title = 'Remove card';
    remove.addEventListener('click', () => options.onRemove?.());
    bar.append(sizes, colors, move, remove);
    return bar;
  }

  return { render, swatches, number };
})();
