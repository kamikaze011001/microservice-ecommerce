import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BMarginNumeral from './BMarginNumeral.vue';

const meta: Meta<typeof BMarginNumeral> = {
  title: 'Primitives/BMarginNumeral',
  component: BMarginNumeral,
  tags: ['autodocs'],
  argTypes: { side: { control: 'inline-radio', options: ['left', 'right'] } },
  args: { numeral: '01', side: 'left' },
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Left: Story = {};
export const Right: Story = { args: { numeral: '02', side: 'right' } };
