import type { Meta, StoryObj } from '@storybook/vue3-vite';
import AddressForm from './AddressForm.vue';
import type { AddressInput } from '@/lib/zod-schemas';

const prefilled: AddressInput = {
  street: '221B Baker Street',
  city: 'London',
  state: 'Greater London',
  postcode: 'NW1 6XE',
  country: 'GB',
  phone: '+44 20 7946 0958',
};

const meta: Meta<typeof AddressForm> = {
  title: 'Patterns/AddressForm',
  component: AddressForm,
  tags: ['autodocs'],
  render: (args) => ({
    components: { AddressForm },
    setup: () => ({ args }),
    template: `<div style="max-width:32rem"><AddressForm v-bind="args" /></div>`,
  }),
};
export default meta;

type Story = StoryObj<typeof meta>;

export const Empty: Story = {};

export const Prefilled: Story = { args: { initial: prefilled } };

export const Pending: Story = { args: { initial: prefilled, pending: true } };
