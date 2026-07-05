import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BImageFallback from './BImageFallback.vue';

const meta: Meta<typeof BImageFallback> = {
  title: 'Patterns/BImageFallback',
  component: BImageFallback,
  tags: ['autodocs'],
  args: { name: 'Field Notes — Ruled Press Jacket' },
};
export default meta;

type Story = StoryObj<typeof meta>;

export const Default: Story = {};

export const LongName: Story = {
  args: { name: 'Letterpress Tote Bag — Limited Run Edition No. 07 of 250' },
};

export const NoName: Story = { args: { name: '' } };
