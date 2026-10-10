import { reactive } from 'vue'

// One app-wide notice line. Errors stay until closed; successes fade.
export const toast = reactive({ text: '', kind: 'ok', timer: null })

export function notify(text, kind = 'ok') {
  clearTimeout(toast.timer)
  Object.assign(toast, { text, kind })
  if (kind === 'ok') toast.timer = setTimeout(() => (toast.text = ''), 6000)
}
