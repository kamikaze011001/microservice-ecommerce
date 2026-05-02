import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/vue';
import BImageFallback from '@/components/BImageFallback.vue';

describe('BImageFallback', () => {
  it('renders cropmark X and product name overlay', () => {
    render(BImageFallback, { props: { name: 'Glass Vase' } });
    expect(screen.getByText(/glass vase/i)).toBeInTheDocument();
  });

  it('exposes a role of img with an aria-label for accessibility', () => {
    render(BImageFallback, { props: { name: 'Brass Lamp' } });
    const el = screen.getByRole('img', { name: /brass lamp/i });
    expect(el).toBeInTheDocument();
  });

  it('renders without crashing when name is empty', () => {
    render(BImageFallback, { props: { name: '' } });
    expect(screen.getByRole('img')).toBeInTheDocument();
  });
});
