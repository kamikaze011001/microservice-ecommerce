import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/vue';
import BMarginNumeral from '@/components/primitives/BMarginNumeral.vue';

describe('BMarginNumeral', () => {
  it('renders the numeral text', () => {
    render(BMarginNumeral, { props: { numeral: '01' } });
    expect(screen.getByText('01')).toBeInTheDocument();
  });

  it('side="right" applies side-right class', () => {
    const { container } = render(BMarginNumeral, {
      props: { numeral: '02', side: 'right' },
    });
    expect(container.querySelector('.b-margin-numeral.side-right')).not.toBeNull();
  });
});
