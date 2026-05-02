import { customRef } from 'vue';

export function useDebouncedRef<T>(initial: T, delay = 400) {
  let timeout: ReturnType<typeof setTimeout> | null = null;
  let value: T = initial;
  return customRef<T>((track, trigger) => ({
    get() {
      track();
      return value;
    },
    set(next: T) {
      if (timeout) clearTimeout(timeout);
      timeout = setTimeout(() => {
        value = next;
        trigger();
      }, delay);
    },
  }));
}
