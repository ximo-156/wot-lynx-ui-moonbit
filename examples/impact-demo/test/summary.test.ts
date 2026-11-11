import { expect, it } from 'vitest'
import { feeSummary } from '../src/summary'

it('formats a fee summary', () => {
  expect(feeSummary(5)).toBe('Fee: 10')
})
