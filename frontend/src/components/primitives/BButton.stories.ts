import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BButton from './BButton.vue';

const meta: Meta<typeof BButton> = {
  title: 'Primitives/BButton',
  component: BButton,
  tags: ['autodocs'],
  argTypes: {
    variant: { control: 'select', options: ['spot', 'ink', 'ghost', 'danger'] },
    type: { control: 'select', options: ['button', 'submit', 'reset'] },
    disabled: { control: 'boolean' },
    loading: { control: 'boolean' },
  },
  args: { variant: 'ink', disabled: false, loading: false },
  render: (args) => ({
    components: { BButton },
    setup: () => ({ args }),
    template: `<BButton v-bind="args">Add to cart</BButton>`,
  }),
};
export default meta;

type Story = StoryObj<typeof meta>;

export const Ink: Story = {};
export const Spot: Story = { args: { variant: 'spot' } };
export const Ghost: Story = { args: { variant: 'ghost' } };
export const Danger: Story = { args: { variant: 'danger' } };
export const Loading: Story = { args: { loading: true } };
