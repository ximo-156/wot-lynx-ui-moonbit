import { formatDate, unusedHelper } from "./helpers";
import { broken } from "./missing";

export function renderDate(date: Date): string {
  // TODO: localise once the locale lands — moonlint-ok
  // this comment line is deliberately much longer than the configured limit
  const formatted = formatDate(date);
  const tag = broken;
  console.log(formatted, tag);
  return formatted;
}
