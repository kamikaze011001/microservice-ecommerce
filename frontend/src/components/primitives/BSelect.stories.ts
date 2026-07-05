import type { Meta, StoryObj } from '@storybook/vue3-vite';
import { ref } from 'vue';
import BSelect from './BSelect.vue';

const OPTIONS = [
  { value: 'standard', label: 'Standard shipping' },
  { value: 'express', label: 'Express (next day)' },
  { value: 'pickup', label: 'Store pickup' },
];

const meta: Meta<typeof BSelect> = {
  title: 'Primitives/BSelect',
  component: BSelect,
  tags: ['autodocs'],
  args: { modelValue: '', options: OPTIONS, placeholder: 'Choose a method' },
  render: (args) => ({
    components: { BSelect },
    setup() {
      const model = ref(args.modelValue);
      return { args, model };
    },
    template: `<div style="max-width:22rem"><BSelect v-bind="args" v-model="model" /></div>`,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
export const WithError: Story = { args: { error: 'Select a shipping method.' } };
export const Disabled: Story = { args: { disabled: true } };
