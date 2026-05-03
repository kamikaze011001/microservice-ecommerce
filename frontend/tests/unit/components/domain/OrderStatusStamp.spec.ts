import { render } from '@testing-library/vue';
import OrderStatusStamp from '@/components/domain/OrderStatusStamp.vue';
import { describe, it, expect } from 'vitest';

describe('OrderStatusStamp', () => {
  it.each([
    ['PENDING', 'PENDING'],
    ['PROCESSING', 'IN PRESS'],
    ['PAID', 'PAID'],
    ['CANCELED', 'VOIDED'],
    ['FAILED', 'MISFIRE'],
  ])('renders status %s as label %s', (status, label) => {
    const { getByText } = render(OrderStatusStamp, { props: { status } });
    expect(getByText(label)).toBeInTheDocument();
  });
});
