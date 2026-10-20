import Foundation

/// The design guide agents read before writing slides (`slides.guide`). Otto's deck engine
/// supplies layout, motion, charts and 3D; agents compose slides from these pieces.
public enum DeckAuthoring {
  public static let guide = """
    # Writing Otto slides

    Every slide is HTML for a 1280×720 canvas. Otto adds the background, padding (72px top and \
    bottom, 88px sides), scaling, motion and charts. Write only the slide's inner HTML: no \
    <html>, <head>, <script> or <style> tags, and no inline event handlers. Use the classes \
    below plus small inline styles when needed. Colours and fonts come from the deck theme as \
    CSS variables: var(--accent), var(--accent2), var(--text), var(--muted), var(--surface), \
    var(--bg), var(--font-display).

    ## Make it beautiful
    - One idea per slide. Big type, few words: a headline and at most 3–5 short points.
    - Lead with a kicker and a strong headline; use .lead for one supporting sentence.
    - Vary the layouts across the deck: title, statement, split, grid of cards, stats, chart, \
    quote, steps, comparison. Never make two text-only slides in a row.
    - Show numbers as .stat count-ups or .chart, not as sentences.
    - Add one backdrop to most slides and motion to key elements (data-anim or .stagger).
    - Keep everything inside the canvas: about 8 lines of body text at most.

    ## Building blocks
    Typography: <h1>, <h2>, <h3>, <p>, .huge (giant headline), .lead, .small, .muted, \
    .kicker (small uppercase label), .gradient-text, .accent, <strong>.
    Layout: .center (centred column, full height), .stack (vertical, 24px gaps), .row, \
    .split (two columns), .split.wide-left, .grid-2, .grid-3, .grid-4, .spacer.
    Blocks: .card (soft panel; put <h3> and <p> inside), .glass, .pill / .badge, \
    <div class="icon">🚀</div>, <ul class="list"> (accent bullets), <ol class="steps"> \
    (numbered timeline cards), <p class="quote"> + <p class="cite">, \
    <table class="compare"> (th header; td.yes for ticks), <img class="cover|rounded" src="https://…">.
    Backdrops (put first in the slide): <div class="backdrop aurora|mesh|grid|dots|spotlight|glow"></div>.
    Brand: <img class="logo" src="…"> sits top right; <div class="brandmark">Name</div> top left.

    ## Data
    Count-up stat: <div class="stat"><div class="value" data-count="12480" data-prefix="$" \
    data-suffix="+" data-decimals="0">12,480+</div><div class="label">Followers</div></div>
    Progress bar: <div class="progress" data-value="72"><i></i></div>
    Chart (animated SVG, give it a height via the class or style):
    <div class="chart" data-type="bar|hbar|line|area|donut" data-labels='["Q1","Q2","Q3"]' \
    data-values='[120,180,260]' data-values2='[90,140,200]' data-names='["2026","2025"]' \
    data-prefix="$" data-suffix="k"></div>
    Use bar for comparisons, line/area for trends, hbar for rankings, donut for shares.

    ## Motion and 3D
    data-anim="up|fade|zoom|left|right" with optional data-delay="200" (ms) on any element; \
    class="stagger" on a container reveals its children one by one. 3D: wrap in .scene3d; \
    .tilt follows the pointer when presenting; .float gently bobs at an angle; .depth-1/2/3 \
    lift layers; <div class="float"><div class="cube"></div></div> is a floating 3D cube \
    in the accent colours.

    ## Examples
    Title:
    <div class="backdrop aurora"></div>
    <div class="center stack"><div class="kicker" data-anim="fade">Series A · 2026</div>
    <h1 class="huge gradient-text" data-anim="up">Otto</h1>
    <p class="lead" data-anim="up" data-delay="150">The personal OS where agents do the busywork.</p></div>

    Stats:
    <div class="backdrop grid"></div>
    <div class="stack"><div class="kicker">Traction</div><h2 data-anim="up">Growing every week</h2>
    <div class="grid-3 stagger">
    <div class="card"><div class="stat"><div class="value" data-count="12480">12,480</div><div class="label">Weekly users</div></div></div>
    <div class="card"><div class="stat"><div class="value" data-count="38" data-suffix="%">38%</div><div class="label">Month-on-month</div></div></div>
    <div class="card"><div class="stat"><div class="value" data-count="4.9" data-decimals="1">4.9</div><div class="label">App Store rating</div></div></div>
    </div></div>

    Chart:
    <div class="split wide-left"><div class="chart" data-type="area" data-labels='["Jan","Feb","Mar","Apr","May","Jun"]' data-values='[12,19,27,41,58,80]' data-suffix="k" style="height:420px"></div>
    <div class="stack"><div class="kicker">Revenue</div><h2 data-anim="up">6× in six months</h2><p class="lead" data-anim="up">Every cohort expands.</p></div></div>

    3D feature:
    <div class="backdrop mesh"></div>
    <div class="split"><div class="stack"><div class="kicker">How it works</div><h2 data-anim="up">Agents that share one memory</h2>
    <ul class="list stagger"><li>Connect your tools once</li><li>Agents remember context</li><li>You approve what matters</li></ul></div>
    <div class="scene3d center"><div class="card glass float tilt" style="width:420px"><div class="icon">🧠</div><h3>Shared memory</h3><p>Every agent sees the same brief.</p></div></div></div>

    ## Brand from a website
    When asked to match a brand, read the site with your web tools, then call slides.set_theme \
    with its colours (hex), fonts (fontDisplay/fontBody plus a Google Fonts fontURL when it uses \
    one), logoURL and brandName. Write in the brand's voice.
    """
}
