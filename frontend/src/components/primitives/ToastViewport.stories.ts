import type { Meta, StoryObj } from '@storybook/vue3-vite';
import ToastViewport from './ToastViewport.vue';
import BButton from './BButton.vue';
import { useToastStore } from '@/stores/toast';

const meta: Meta<typeof ToastViewport> = {
  title: 'Primitives/ToastViewport',
  component: ToastViewport,
  tags: ['autodocs'],
  render: () => ({
    components: { ToastViewport, BButton },
    setup() {
      const toasts = useToastStore();
      const fire = () =>
        toasts.push({ tone: 'success', title: 'Added to cart', body: 'Riso Print Nº01' });
      return { fire };
    },
    template: `<div><BButton @click="fire">Fire toast</BButton><ToastViewport /></div>`,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
