import { describe, it, expect } from 'vitest';
import { formatAddress } from '@/lib/format';

describe('formatAddress', () => {
  it('joins parts into a single line', () => {
    expect(
      formatAddress({
        street: '123 Main St',
        city: 'Brooklyn',
        state: 'NY',
        postcode: '11201',
        country: 'US',
      }),
    ).toBe('123 Main St, Brooklyn, NY 11201, US');
  });
});
