import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(resolve(here, '../../src/styles/tokens.css'), 'utf-8');

describe('tokens.css', () => {
  it('declares the Issue Nº01 palette', () => {
    expect(css).toMatch(/--paper:\s*#f4efe6/i);
    expect(css).toMatch(/--ink:\s*#1c1c1c/i);
    expect(css).toMatch(/--spot:\s*#ff4f1c/i);
    expect(css).toMatch(/--stamp-red:\s*#c4302b/i);
  });

  it('declares the type stack', () => {
    expect(css).toMatch(/--font-display:.*Bricolage Grotesque/);
    expect(css).toMatch(/--font-body:.*Cabinet Grotesk/);
    expect(css).toMatch(/--font-mono:.*Departure Mono/);
  });

  it('declares mechanical motion tokens', () => {
    expect(css).toMatch(/--press-translate:\s*4px/);
    expect(css).toMatch(/--transition-snap:\s*60ms\s+steps\(2\)/);
  });
});
