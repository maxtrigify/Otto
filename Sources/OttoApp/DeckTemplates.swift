import Foundation

/// Ready-made slide designs for "New slide". Each one uses the deck engine's components, so it
/// follows the deck's theme or brand automatically.
enum DeckTemplates {
  static let all: [(name: String, symbol: String, html: String)] = [
    (
      "Title", "textformat.size.larger",
      """
      <div class="backdrop aurora"></div>
      <div class="center stack"><div class="kicker" data-anim="fade">Kicker</div>
      <h1 class="huge gradient-text" data-anim="up">Big idea</h1>
      <p class="lead" data-anim="up" data-delay="150">One sentence that makes people lean in.</p></div>
      """
    ),
    (
      "Statement", "quote.opening",
      """
      <div class="backdrop spotlight"></div>
      <div class="stack" style="max-width:1000px"><div class="kicker" data-anim="fade">The problem</div>
      <h1 data-anim="up">Say the one thing you want them to remember.</h1></div>
      """
    ),
    (
      "Points", "list.bullet",
      """
      <div class="backdrop mesh"></div>
      <div class="split"><div class="stack"><div class="kicker">Why now</div>
      <h2 data-anim="up">Three reasons</h2></div>
      <ul class="list stagger"><li>First reason, short</li><li>Second reason, short</li><li>Third reason, short</li></ul></div>
      """
    ),
    (
      "Cards", "square.grid.3x1.below.line.grid.1x2",
      """
      <div class="stack"><div class="kicker">What you get</div><h2 data-anim="up">Built for the way you work</h2>
      <div class="grid-3 stagger">
      <div class="card"><div class="icon">⚡️</div><h3>Fast</h3><p>One line on why it matters.</p></div>
      <div class="card"><div class="icon">🧠</div><h3>Smart</h3><p>One line on why it matters.</p></div>
      <div class="card"><div class="icon">🔒</div><h3>Private</h3><p>One line on why it matters.</p></div>
      </div></div>
      """
    ),
    (
      "Stats", "number",
      """
      <div class="backdrop grid"></div>
      <div class="stack"><div class="kicker">Traction</div><h2 data-anim="up">The numbers</h2>
      <div class="grid-3 stagger">
      <div class="card"><div class="stat"><div class="value" data-count="12480">12,480</div><div class="label">Weekly users</div></div></div>
      <div class="card"><div class="stat"><div class="value" data-count="38" data-suffix="%">38%</div><div class="label">Growth a month</div></div></div>
      <div class="card"><div class="stat"><div class="value" data-count="4.9" data-decimals="1">4.9</div><div class="label">Rating</div></div></div>
      </div></div>
      """
    ),
    (
      "Chart", "chart.bar.xaxis",
      """
      <div class="split wide-left">
      <div class="chart" data-type="bar" data-labels='["Q1","Q2","Q3","Q4"]' data-values='[24,38,55,81]' data-suffix="k" style="height:440px"></div>
      <div class="stack"><div class="kicker">Revenue</div><h2 data-anim="up">Up and to the right</h2>
      <p class="lead" data-anim="up" data-delay="150">Say what the chart means in one line.</p></div></div>
      """
    ),
    (
      "Trend", "chart.line.uptrend.xyaxis",
      """
      <div class="backdrop glow"></div>
      <div class="stack"><div class="kicker">Growth</div><h2 data-anim="up">Steady every month</h2>
      <div class="chart" data-type="area" data-labels='["Jan","Feb","Mar","Apr","May","Jun"]' data-values='[12,19,27,41,58,80]' style="height:400px"></div></div>
      """
    ),
    (
      "Steps", "list.number",
      """
      <div class="stack"><div class="kicker">How it works</div><h2 data-anim="up">Three steps</h2>
      <ol class="steps stagger"><li><strong>Connect</strong><br>Your tools, once.</li>
      <li><strong>Ask</strong><br>In plain words.</li><li><strong>Done</strong><br>Agents do the work.</li></ol></div>
      """
    ),
    (
      "Quote", "text.quote",
      """
      <div class="backdrop aurora"></div>
      <div class="center stack" style="max-width:1000px;margin:0 auto">
      <p class="quote" data-anim="up">This changed how our whole team works.</p>
      <p class="cite" data-anim="fade" data-delay="300">Name, Role at Company</p></div>
      """
    ),
    (
      "Compare", "tablecells",
      """
      <div class="stack"><div class="kicker">Why us</div><h2 data-anim="up">How we compare</h2>
      <table class="compare" data-anim="up"><tr><th>Feature</th><th>Us</th><th>Them</th></tr>
      <tr><td>Agents that remember</td><td class="yes">✓</td><td>—</td></tr>
      <tr><td>Works with your tools</td><td class="yes">✓</td><td>Some</td></tr>
      <tr><td>Private by default</td><td class="yes">✓</td><td>—</td></tr></table></div>
      """
    ),
    (
      "3D feature", "cube.transparent",
      """
      <div class="backdrop mesh"></div>
      <div class="split"><div class="stack"><div class="kicker">Feature</div><h2 data-anim="up">A headline for it</h2>
      <p class="lead" data-anim="up" data-delay="150">One line on what it does for people.</p></div>
      <div class="scene3d center"><div class="float"><div class="cube"></div></div></div></div>
      """
    ),
    (
      "Closing", "flag.checkered",
      """
      <div class="backdrop spotlight"></div>
      <div class="center stack"><h1 class="huge gradient-text" data-anim="zoom">Thank you</h1>
      <p class="lead" data-anim="up" data-delay="200">name@company.com</p></div>
      """
    ),
  ]
}
