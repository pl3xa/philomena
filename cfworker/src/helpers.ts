// Secure 20-char secret for Cloudflare Workers (TypeScript)
export function generateSecret(
  length = 20,
  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
): string {
  const n = alphabet.length;
  if (n < 2 || n > 256) throw new Error("alphabet size must be between 2 and 256");

  const max = Math.floor(256 / n) * n; // rejection threshold to avoid modulo bias
  const out: string[] = [];
  const buf = new Uint8Array(length * 2); // oversample to reduce getRandomValues calls

  while (out.length < length) {
    crypto.getRandomValues(buf);
    for (const b of buf) {
      if (b >= max) continue;
      out.push(alphabet[b % n]);
      if (out.length === length) break;
    }
  }
  return out.join("");
}
