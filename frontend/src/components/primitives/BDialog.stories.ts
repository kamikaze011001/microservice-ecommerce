import type { Meta, StoryObj } from '@storybook/vue3-vite';
import { ref } from 'vue';
import BDialog from './BDialog.vue';
import BButton from './BButton.vue';

const meta: Meta<typeof BDialog> = {
  title: 'Primitives/BDialog',
  component: BDialog,
  tags: ['autodocs'],
  args: { open: false, title: 'Cancel this order?', description: 'This cannot be undone.' },
  render: (args) => ({
    components: { BDialog, BButton },
    setup() {
      const open = ref(args.open);
      return { args, open };
    },
    template: `
      <div>
        <BButton variant="danger" @click="open = true">Cancel order</BButton>
        <BDialog v-bind="args" :open="open" @update:open="(v) => (open = v)">
          <p>Order #A-0042 will be canceled and stock released.</p>
        </BDialog>
      </div>`,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
