//// Test suite for the `screenshot` library. It doubles as living
//// documentation: the screenshot tests exercise common CSS features across the
//// mobile, tablet and desktop screen sizes — flexbox, CSS grid, gradients and
//// borders, text wrapping/reflow, and media-query layout — and show both the
//// raw-HTML and the (optional) Lustre entry points. The same suite runs on the
//// JavaScript target and on the BEAM.
////
//// Screenshot tests are skipped unless `CHROME_BIN` and `ODIFF_BIN` are set,
//// so `gleam test` still runs on a machine without a browser.

import envoy
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import lustre/attribute
import lustre/element
import lustre/element/html
import screenshot
import simplifile

pub fn main() {
  gleeunit.main()
}

// MARK: Screenshot regression tests (need CHROME_BIN + ODIFF_BIN)

/// Flexbox layout — three evenly distributed colour blocks at mobile size.
pub fn flexbox_mobile_test() {
  use <- skip_without_browser
  let content =
    "<div class=\"row\">"
    <> "<div class=\"box a\"></div>"
    <> "<div class=\"box b\"></div>"
    <> "<div class=\"box c\"></div>"
    <> "</div>"

  matches("flexbox", content, screenshot.mobile)
}

/// CSS grid — a 3-column gallery of bordered cells at tablet size.
pub fn grid_tablet_test() {
  use <- skip_without_browser
  let cells =
    list.repeat("<div class=\"cell\"></div>", 9)
    |> string.join("")
  let content = "<div class=\"grid\">" <> cells <> "</div>"

  matches("grid", content, screenshot.tablet)
}

/// Gradient + border + border-radius — a card at desktop size. Also the
/// one fixture with text, so a font regression would surface here.
pub fn card_desktop_test() {
  use <- skip_without_browser
  let content =
    "<div class=\"card\">"
    <> "<h2>Screenshot regression</h2>"
    <> "<p>Renders raw HTML, diffs against a baseline.</p>"
    <> "</div>"

  matches("card", content, screenshot.desktop)
}

/// Running text that wraps. The same paragraph reflows to a different number
/// of lines at mobile vs desktop width, so each size gets its own baseline —
/// a font-size / line-height / measure / wrapping regression surfaces here.
const prose = "<article class=\"prose\">"
  <> "<h1>On memorising poems</h1>"
  <> "<p>Spaced repetition turns a wall of unfamiliar verse into something "
  <> "you can recall on demand. Each card surfaces a line just before you "
  <> "would have forgotten it, and the interval stretches a little further "
  <> "every time you succeed.</p>"
  <> "<p>The trick is to keep the sessions short and frequent. A few minutes "
  <> "of cloze deletion in the morning beats an hour of staring on a Sunday "
  <> "afternoon, because the forgetting curve is steepest in the first days.</p>"
  <> "</article>"

pub fn text_wrapping_mobile_test() {
  use <- skip_without_browser
  matches("prose_mobile", prose, screenshot.mobile)
}

pub fn text_wrapping_desktop_test() {
  use <- skip_without_browser
  matches("prose_desktop", prose, screenshot.desktop)
}

/// Media-query layout — the same sidebar + main markup stacks on mobile and
/// sits side-by-side on desktop. The two baselines are visibly different
/// (stacked vs columns), so they document at a glance that the viewport width
/// reached the page and the breakpoint flipped the layout.
const layout = "<div class=\"layout\">"
  <> "<div class=\"side\"></div>"
  <> "<div class=\"main\"></div>"
  <> "</div>"

pub fn responsive_mobile_test() {
  use <- skip_without_browser
  matches("responsive_mobile", layout, screenshot.mobile)
}

pub fn responsive_desktop_test() {
  use <- skip_without_browser
  matches("responsive_desktop", layout, screenshot.desktop)
}

/// Optional Lustre interop: build a view with Lustre, stringify it with
/// `lustre/element.to_string`, and feed that to the same primitive. The
/// library itself never imports Lustre.
pub fn lustre_element_test() {
  use <- skip_without_browser
  let view =
    html.div([attribute.class("card")], [
      html.h2([], [element.text("Built with Lustre")]),
      html.p([], [element.text("element.to_string -> screenshot")]),
    ])

  matches("lustre", element.to_string(view), screenshot.desktop)
}

// MARK: Helpers

/// Wrap a fragment in a complete HTML document with the fixture stylesheet
/// inlined, so the render is self-contained — the document path the library
/// exposes on every target.
fn document(content: String) -> String {
  let assert Ok(css) = simplifile.read("test/fixtures/styles.css")
  "<!doctype html>
<html lang=\"en\">
  <head>
    <meta charset=\"UTF-8\" />
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\" />
    <style>" <> css <> "</style>
  </head>
  <body>
    <div id=\"app\">" <> content <> "</div>
  </body>
</html>"
}

fn matches(name: String, content: String, size: screenshot.ScreenSize) -> Nil {
  screenshot.document_matches_baseline(
    document: document(content),
    baseline: "test/screenshots/" <> name,
    size:,
    threshold: 0.1,
  )
  |> should.equal(Ok(screenshot.Match))
}

fn skip_without_browser(run: fn() -> Nil) -> Nil {
  case envoy.get("CHROME_BIN"), envoy.get("ODIFF_BIN") {
    Ok(_), Ok(_) -> run()
    _, _ -> Nil
  }
}
