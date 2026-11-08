import assert from "node:assert/strict";
import test from "node:test";

import { curvePrice } from "../src/priceCurve.js";

function referencePrice(startingPrice, reservePrice, curve, elapsed) {
  if (elapsed === 0n) return startingPrice;
  if (elapsed >= 1_200n) return reservePrice;

  const remaining = 1_200n - elapsed;
  const numerator = curve === 0
    ? remaining
    : curve === 1
      ? 1_200n * 1_200n - elapsed * elapsed
      : remaining * remaining;
  const denominator = curve === 0 ? 1_200n : 1_200n * 1_200n;
  const spread = startingPrice - reservePrice;
  const premium = (spread * numerator + denominator - 1n) / denominator;
  return reservePrice + premium;
}

test("frontend price curves match the integer reference at every second", () => {
  const startingPrice = 10n ** 16n;
  const reservePrice = 4n * 10n ** 15n;

  for (let curve = 0; curve < 3; curve += 1) {
    let previous = startingPrice;
    for (let elapsed = 0n; elapsed <= 1_200n; elapsed += 1n) {
      const price = curvePrice(startingPrice, reservePrice, curve, elapsed);
      assert.equal(price, referencePrice(startingPrice, reservePrice, curve, elapsed));
      assert.ok(price <= previous, `curve ${curve} increased at second ${elapsed}`);
      assert.ok(price >= reservePrice, `curve ${curve} fell below reserve at second ${elapsed}`);
      if (elapsed < 1_200n) assert.ok(price > reservePrice, `curve ${curve} reached reserve early`);
      previous = price;
    }
  }
});

test("narrow spreads preserve price plateaus and clamp elapsed time", () => {
  for (let curve = 0; curve < 3; curve += 1) {
    assert.equal(curvePrice(2n, 1n, curve, 1n), 2n);
    assert.equal(curvePrice(2n, 1n, curve, 1_199n), 2n);
    assert.equal(curvePrice(2n, 1n, curve, 1_200n), 1n);
    assert.equal(curvePrice(2n, 1n, curve, 1_500n), 1n);
    assert.equal(curvePrice(2n, 1n, curve, -5n), 2n);
  }
});
