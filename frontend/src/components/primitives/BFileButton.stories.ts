import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BFileButton from './BFileButton.vue';

const meta: Meta<typeof BFileButton> = {
  title: 'Primitives/BFileButton',
  component: BFileButton,
  tags: ['autodocs'],
  argTypes: {
    variant: { control: 'select', options: ['spot', 'ink', 'ghost', 'danger'] },
    accept: { control: 'text' },
    loading: { control: 'boolean' },
    disabled: { control: 'boolean' },
    onSelect: { action: 'select' },
  },
  args: { variant: 'spot', loading: false, disabled: false, accept: 'image/png,image/jpeg' },
  render: (args) => ({
    components: { BFileButton },
    setup: () => ({ args }),
    template: `<BFileButton v-bind="args" @select="args.onSelect">CHANGE PHOTO</BFileButton>`,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
export const Loading: Story = { args: { loading: true } };
export const Disabled: Story = { args: { disabled: true } };
