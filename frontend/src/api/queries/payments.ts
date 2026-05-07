import { useMutation } from '@tanstack/vue-query';
import { apiFetchUnsafe } from '@/api/client';

interface PaypalLink {
  rel: string;
  href: string;
}

interface PaypalOrderSimple {
  id: string;
  links: PaypalLink[];
}

export interface CreatePaymentInput {
  orderId: string;
}

export interface CreatePaymentResult {
  approvalUrl: string;
}

export function useCreatePaymentMutation() {
  return useMutation({
    mutationFn: async (input: CreatePaymentInput): Promise<CreatePaymentResult> => {
      const raw = await apiFetchUnsafe<PaypalOrderSimple>(
        `/payment-service/v1/payments?orderId=${encodeURIComponent(input.orderId)}`,
        { method: 'POST' },
      );
      const approve = raw.links?.find((l) => l.rel === 'approve' || l.rel === 'payer-action');
      if (!approve) {
        throw new Error('PayPal response missing approval link');
      }
      return { approvalUrl: approve.href };
    },
  });
}
