import { useToastStore, type ToastInput } from '@/stores/toast';

type Opts = Pick<ToastInput, 'duration'>;

export function useToast() {
  const store = useToastStore();
  return {
    info: (title: string, body?: string, opts?: Opts) =>
      store.push({ tone: 'info', title, body, ...opts }),
    success: (title: string, body?: string, opts?: Opts) =>
      store.push({ tone: 'success', title, body, ...opts }),
    error: (title: string, body?: string, opts?: Opts) =>
      store.push({ tone: 'error', title, body, ...opts }),
    dismiss: (id: string) => store.dismiss(id),
  };
}
