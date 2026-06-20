import { parseHTML } from "linkedom";
import { Ok, Error } from "../gleam.mjs";

export function mount_into_template(template_html, selector, content_html) {
  const { document } = parseHTML(template_html);
  const target = document.querySelector(selector);
  if (!target) {
    return new Error(`template has no element matching "${selector}"`);
  }
  target.innerHTML = content_html;
  return new Ok(document.toString());
}

export function platform() {
  return process.platform;
}
