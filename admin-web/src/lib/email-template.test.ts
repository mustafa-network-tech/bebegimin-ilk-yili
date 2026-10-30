import { test } from "node:test";
import assert from "node:assert/strict";

import { mailtoHref, renderTemplate } from "./email-template.ts";

test("known placeholders are replaced, with or without spaces", () => {
  const out = renderTemplate("Merhaba {{ad}} ve {{ ad }}, bitiş {{deneme_bitis}}", { ad: "Yağmur", deneme_bitis: "1 Kasım" });
  assert.equal(out, "Merhaba Yağmur ve Yağmur, bitiş 1 Kasım");
});

test("unknown placeholders and markup are left as plain text", () => {
  const out = renderTemplate("{{kart_no}} <b>x</b>", { ad: "A", deneme_bitis: "B" });
  assert.equal(out, "{{kart_no}} <b>x</b>");
});

test("a user name is inserted verbatim, never interpreted", () => {
  assert.equal(renderTemplate("{{ad}}", { ad: "{{deneme_bitis}}", deneme_bitis: "X" }), "{{deneme_bitis}}");
});

test("mailto encodes every part and needs an address", () => {
  assert.equal(mailtoHref(null, "a", "b"), null);
  assert.equal(mailtoHref("a@b.com", "Hoş geldin", "Satır 1\nSatır 2"), "mailto:a%40b.com?subject=Ho%C5%9F%20geldin&body=Sat%C4%B1r%201%0ASat%C4%B1r%202");
});
