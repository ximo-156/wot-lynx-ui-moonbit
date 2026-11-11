export function calculateFee(minutes: number, pricePerMinute: number): number {
  return Math.max(0, minutes) * pricePerMinute
}
