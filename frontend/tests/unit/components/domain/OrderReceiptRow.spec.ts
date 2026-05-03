import { render } from '@testing-library/vue';
import { createMemoryHistory, createRouter } from 'vue-router';
import { describe, it, expect } from 'vitest';
import OrderReceiptRow from '@/components/domain/OrderReceiptRow.vue';

const router = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/account/orders/:id', component: { template: '<div/>' } }],
});

describe('OrderReceiptRow', () => {
  it('renders status label, total, item count, and links to detail', async () => {
    const summary = {
      id: 'abc12345-0000-0000-0000-000000000000',
      status: 'PAID',
      address: 'X',
      phone_number: '+1',
      created_at: '2026-05-01T00:00:00Z',
      updated_at: '2026-05-01T00:00:00Z',
      total_amount: 19.98,
      item_count: 2,
      first_item_image_url: null,
    };
    const { getByText, getByRole } = render(OrderReceiptRow, {
      props: { summary },
      global: { plugins: [router] },
    });
    expect(getByText('PAID')).toBeInTheDocument();
    expect(getByText(/\$19\.98/)).toBeInTheDocument();
    expect(getByText(/2 ITEMS|2 items/i)).toBeInTheDocument();
    expect(getByRole('link')).toHaveAttribute(
      'href',
      '/account/orders/abc12345-0000-0000-0000-000000000000',
    );
  });
});
