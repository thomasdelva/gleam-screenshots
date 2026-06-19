//// Test suite for the `screenshot` library. It doubles as living
//// documentation: the screenshot tests exercise common CSS features
//// (flexbox, grid, gradients, borders, media queries) across the mobile,
//// tablet and desktop screen sizes, and show both the raw-HTML and the
//// (optional) Lustre entry points.
////
//// Screenshot tests are skipped unless `CHROME_BIN` and `ODIFF_BIN` are set,
//// so `gleam test` still runs the pure tests on a machine without a browser.

import envoy
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import lustre/attribute
import lustre/element
import lustre/element/html
import screenshot

pub fn main() {
  gleeunit.main()
}

const template = "test/fixtures/template.html"

const selector = "#app"

// MARK: Pure tests (no browser required)

pub fn render_injects_content_test() {
  let assert Ok(combined) =
    screenshot.render(
      content: "<p class=\"hi\">hello</p>",
      into: template,
      at: selector,
    )

  // The fragment lands inside the mount node, and the template chrome
  // (its stylesheet link) is preserved.
  should.be_true(string.contains(combined, "<p class=\"hi\">hello</p>"))
  should.be_true(string.contains(combined, "styles.css"))
}

pub fn render_unknown_selector_is_an_error_test() {
  screenshot.render(content: "<p></p>", into: template, at: "#does-not-exist")
  |> should.equal(Error(screenshot.SelectorNotFound("#does-not-exist")))
}

pub fn render_missing_template_is_an_error_test() {
  screenshot.render(
    content: "<p></p>",
    into: "test/fixtures/nope.html",
    at: selector,
  )
  |> should.equal(Error(screenshot.TemplateNotFound("test/fixtures/nope.html")))
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

/// Media queries — the same markup renders amber on a narrow viewport and
/// green on a wide one. Two baselines prove the ScreenSize reaches the page.
pub fn responsive_narrow_test() {
  use <- skip_without_browser
  matches(
    "responsive_narrow",
    "<div class=\"responsive\"></div>",
    screenshot.mobile,
  )
}

pub fn responsive_wide_test() {
  use <- skip_without_browser
  matches(
    "responsive_wide",
    "<div class=\"responsive\"></div>",
    screenshot.desktop,
  )
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

fn matches(name: String, content: String, size: screenshot.ScreenSize) -> Nil {
  screenshot.matches_baseline(
    content:,
    baseline: "test/screenshots/" <> name,
    options: screenshot.options(template:, selector:)
      |> screenshot.with_size(size),
  )
  |> should.equal(Ok(screenshot.Match))
}

fn skip_without_browser(run: fn() -> Nil) -> Nil {
  case envoy.get("CHROME_BIN"), envoy.get("ODIFF_BIN") {
    Ok(_), Ok(_) -> run()
    _, _ -> Nil
  }
}
