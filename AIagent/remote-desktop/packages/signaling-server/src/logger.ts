export function log(message: string): void {
  const ts = new Date().toISOString();
  console.log(`[${ts}] ${message}`);
}
