import { defineStore } from 'pinia';
import { ref } from 'vue';

export type ToastTone = 'info' | 'success' | 'error';

export interface ToastItem {
  id: string;
  tone: ToastTone;
  title: string;
  body?: string;
  duration: number;
}

export interface ToastInput {
  tone?: ToastTone;
  title: string;
  body?: string;
  duration?: number;
}

// crypto.randomUUID() is only defined in a secure context (HTTPS or
// localhost). Served over plain http:// (e.g. http://microecom.local) it's
// undefined and throws "crypto.randomUUID is not a function", breaking every
// toast. Toast ids only need per-session uniqueness, so fall back to a
// counter + timestamp.
let toastSeq = 0;
function nextToastId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  toastSeq += 1;
  return `toast-${Date.now()}-${toastSeq}`;
}

export const useToastStore = defineStore('toast', () => {
  const items = ref<ToastItem[]>([]);
  const timers = new Map<string, ReturnType<typeof setTimeout>>();

  function push(input: ToastInput): string {
    const id = nextToastId();
    const item: ToastItem = {
      id,
      tone: input.tone ?? 'info',
      title: input.title,
      body: input.body,
      duration: input.duration ?? 4000,
    };
    items.value.push(item);
    timers.set(
      id,
      setTimeout(() => dismiss(id), item.duration),
    );
    return id;
  }

  function dismiss(id: string): void {
    const t = timers.get(id);
    if (t) {
      clearTimeout(t);
      timers.delete(id);
    }
    items.value = items.value.filter((i) => i.id !== id);
  }

  function clear(): void {
    timers.forEach((t) => clearTimeout(t));
    timers.clear();
    items.value = [];
  }

  return { items, push, dismiss, clear };
});
