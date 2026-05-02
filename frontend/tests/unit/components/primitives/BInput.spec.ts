import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { ref } from 'vue';
import BInput from '@/components/primitives/BInput.vue';

describe('BInput', () => {
  it('two-way binds via v-model', async () => {
    const model = ref('');
    render({
      components: { BInput },
      setup: () => ({ model }),
      template: `<BInput v-model="model" label="Name" />`,
    });
    const input = screen.getByLabelText('Name');
    await userEvent.type(input, 'Sona');
    expect(model.value).toBe('Sona');
  });

  it('error prop renders message and applies has-error class', () => {
    const { container } = render(BInput, {
      props: { modelValue: '', error: 'Required' },
    });
    expect(screen.getByText('Required')).toBeInTheDocument();
    expect(container.querySelector('.b-input.has-error')).not.toBeNull();
  });
});
