import type { Meta, StoryObj } from '@storybook/vue3-vite';
import { ref } from 'vue';
import BInput from './BInput.vue';

const meta: Meta<typeof BInput> = {
  title: 'Primitives/BInput',
  component: BInput,
  tags: ['autodocs'],
  argTypes: {
    type: { control: 'text' },
    disabled: { control: 'boolean' },
  },
  args: { label: 'Email', placeholder: 'you@example.com', modelValue: '', type: 'email' },
  render: (args) => ({
    components: { BInput },
    setup() {
      const model = ref(args.modelValue);
      return { args, model };
    },
    template: `<div style="max-width:22rem"><BInput v-bind="args" v-model="model" /></div>`,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
export const WithError: Story = { args: { error: 'Enter a valid email address.' } };
export const Disabled: Story = { args: { disabled: true, modelValue: 'locked@example.com' } };
