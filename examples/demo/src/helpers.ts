export function formatDate(date: Date): string {
  // TODO: honour the caller's locale
  return date.toISOString().slice(0, 10);
}

export function unusedHelper(): string {
  return "nobody imports me";
}

export const alsoUnused = 42;
