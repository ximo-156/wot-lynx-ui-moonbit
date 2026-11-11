import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { expect, it } from 'vitest'

const ROOT = process.cwd()

// This name is deliberately absent from file_readers: the limited single
// return body is proved by the static adapter instead of trusted by name.
function read(file: string): string {
  return readFileSync(resolve(ROOT, file), 'utf8')
}

it('loads the theme as a file input, not a module import', () => {
  const css = read('src/theme.css')
  expect(css).toContain('--surface: white;')
})
