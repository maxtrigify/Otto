'use strict';

// The workspace theme, applied the way the Mac app draws it (OttoPalette, ThemeBackgroundView).
// The engine serves the definition and its derived readability values, so the Mac and the
// desktop app always agree on what a theme looks like.
const Theme = (() => {
  // Halcyon, used until the engine answers (and when no engine is available).
  const fallback = {
    theme: {
      id: 'halcyon',
      displayName: 'Halcyon',
      backgroundAsset: 'halcyon',
      ink: { red: 0.075, green: 0.063, blue: 0.095 },
      surface: { red: 0.12, green: 0.1, blue: 0.14 },
      raised: { red: 0.17, green: 0.13, blue: 0.16 },
      paper: { red: 0.96, green: 0.91, blue: 0.82 },
      muted: { red: 0.68, green: 0.63, blue: 0.62 },
      signal: { red: 0.91, green: 0.53, blue: 0.29 },
      amber: { red: 0.95, green: 0.72, blue: 0.32 },
      red: { red: 0.94, green: 0.35, blue: 0.3 },
      cyan: { red: 0.4, green: 0.79, blue: 0.76 },
    },
    material: 'glass-dark',
    isLight: false,
    scrimFloor: 0.42,
    scrimDeep: 0.7,
    chromeBandOpacity: 0.74,
    themes: [],
  };
  // Artwork shipped with the desktop app (converted from the Mac app's HEIC backdrops).
  const artwork = new Set([
    'duneveil', 'farfield', 'halcyon', 'highfell', 'mistfall',
    'nightscreen', 'nightspire', 'ringfall', 'shorelight', 'silverbough',
  ]);
  let current = fallback;

  const rgb = (color) =>
    `${Math.round(color.red * 255)}, ${Math.round(color.green * 255)}, ${Math.round(color.blue * 255)}`;

  function apply(appearance) {
    current = appearance || fallback;
    const { theme, material, isLight } = current;
    const root = document.documentElement.style;
    for (const key of ['ink', 'surface', 'raised', 'paper', 'muted', 'signal', 'amber', 'red', 'cyan']) {
      root.setProperty(`--${key}-rgb`, rgb(theme[key]));
    }
    // Home and Chat keep the photo nearly clear: the contract scrim at a quarter strength.
    const scale = 0.25;
    const windowGlass = material === 'window-glass';
    const tone = windowGlass ? rgb(theme.surface) : rgb(theme.ink);
    const base = current.scrimFloor * scale;
    root.setProperty('--scrim-top', `rgba(${tone}, ${base})`);
    root.setProperty('--scrim-mid', `rgba(${tone}, ${base + (windowGlass ? 0.04 : 0.1) * scale})`);
    root.setProperty('--scrim-bottom', `rgba(${tone}, ${current.scrimDeep * scale})`);
    root.setProperty('--chrome-band', `rgba(${rgb(theme.ink)}, ${current.chromeBandOpacity})`);
    const asset = theme.backgroundAsset && artwork.has(theme.backgroundAsset) ? theme.backgroundAsset : null;
    root.setProperty('--artwork', asset ? `url("themes/${asset}.jpg")` : 'none');
    document.body.classList.toggle('has-artwork', Boolean(asset));
    document.body.classList.toggle('light', Boolean(isLight));
    document.body.dataset.material = material;
  }

  async function load() {
    try {
      apply(await window.otto.desktop('appearance.get'));
    } catch {
      apply(fallback);
    }
    return current;
  }

  async function choose(themeID) {
    apply(await window.otto.desktop('appearance.set', { themeID }));
    return current;
  }

  apply(fallback);
  return {
    load,
    choose,
    get current() {
      return current;
    },
  };
})();
