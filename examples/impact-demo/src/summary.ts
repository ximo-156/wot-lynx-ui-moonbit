import { calculateFee } from './fees'

export function feeSummary(minutes: number): string {
  return `Fee: ${calculateFee(minutes, 2)}`
}
