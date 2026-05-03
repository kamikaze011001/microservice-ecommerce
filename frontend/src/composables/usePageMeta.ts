import { onUnmounted, watchEffect, type Ref, isRef } from 'vue';

const DEFAULT_DESCRIPTION = 'Issue Nº01 — a small editorial storefront.';

function setMeta(name: string, value: string) {
  let el = document.querySelector(`meta[name="${name}"]`) as HTMLMetaElement | null;
  if (!el) {
    el = document.createElement('meta');
    el.name = name;
    document.head.appendChild(el);
  }
  el.content = value;
}

export function usePageMeta(opts: {
  title: string | Ref<string>;
  description?: string | Ref<string>;
}) {
  const initialTitle = document.title;
  const initialDesc =
    (document.querySelector('meta[name="description"]') as HTMLMetaElement | null)?.content ??
    DEFAULT_DESCRIPTION;

  watchEffect(() => {
    const t = isRef(opts.title) ? opts.title.value : opts.title;
    const d = opts.description
      ? isRef(opts.description)
        ? opts.description.value
        : opts.description
      : DEFAULT_DESCRIPTION;
    document.title = t;
    setMeta('description', d);
  });

  onUnmounted(() => {
    document.title = initialTitle;
    setMeta('description', initialDesc);
  });
}
