const DURATION = 1_200n;
const CURVE_DENOMINATOR = DURATION * DURATION;

export function curvePrice(startingPrice, reservePrice, curve, elapsed) {
  const time = elapsed < 0n ? 0n : elapsed > DURATION ? DURATION : elapsed;
  if (time === 0n) return startingPrice;
  if (time === DURATION) return reservePrice;

  const spread = startingPrice - reservePrice;
  const remaining = DURATION - time;
  let numerator;
  let denominator;
  if (curve === 0) {
    numerator = remaining;
    denominator = DURATION;
  } else if (curve === 1) {
    numerator = CURVE_DENOMINATOR - time * time;
    denominator = CURVE_DENOMINATOR;
  } else if (curve === 2) {
    numerator = remaining * remaining;
    denominator = CURVE_DENOMINATOR;
  } else {
    throw new RangeError("Unknown Dutch auction price curve.");
  }

  const premium = (spread * numerator + denominator - 1n) / denominator;
  return reservePrice + premium;
}
