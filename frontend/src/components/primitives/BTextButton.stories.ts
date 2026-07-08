import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BTextButton from './BTextButton.vue';

const meta: Meta<typeof BTextButton> = {
  title: 'Primitives/BTextButton',
  component: BTextButton,
  tags: ['autodocs'],
  argTypes: {
    disabled: { control: 'boolean' },
    type: { control: 'select', options: ['button', 'submit', 'reset'] },
  },
  args: { disabled: false, type: 'button' },
  render: (args) => ({
    components: { BTextButton },
    setup: () => ({ args }),
    template: `<BTextButton v-bind="args">LOG OUT</BTextButton>`,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
export const Disabled: Story = { args: { disabled: true } };
