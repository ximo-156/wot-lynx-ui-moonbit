import { describe, expect, it } from 'vitest'
import { calculateFee } from '../src/fees'

describe('charging fee', () => {
  it('calculates the amount', () => {
    expect(calculateFee(5, 2)).toBe(10)
  })
  it('does not charge for negative durations', () => {
    expect(calculateFee(-1, 2)).toBe(0)
  })
})
