export function hashRotate(seed: string, maxDegrees = 0.5): number {
  let h = 2166136261;
  for (let i = 0; i < seed.length; i++) {
    h ^= seed.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  const norm = (h >>> 0) / 0xffffffff;
  return (norm * 2 - 1) * maxDegrees;
}
