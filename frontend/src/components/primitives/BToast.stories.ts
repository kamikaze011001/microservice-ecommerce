import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BToast from './BToast.vue';

const meta: Meta<typeof BToast> = {
  title: 'Primitives/BToast',
  component: BToast,
  tags: ['autodocs'],
  argTypes: { tone: { control: 'inline-radio', options: ['info', 'success', 'error'] } },
  args: { tone: 'success', title: 'Added to cart', body: 'Riso Print Nº01 × 1' },
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Success: Story = {};
export const Info: Story = {
  args: { tone: 'info', title: 'Heads up', body: 'Your session expires soon.' },
};
export const Error: Story = {
  args: { tone: 'error', title: 'Payment failed', body: 'Card was declined.' },
};
