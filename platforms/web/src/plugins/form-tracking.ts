// Form tracking từng field — focus / blur / change / submit.
//
// Trả lời câu "người dùng bỏ dở form ở ô nào": `form_field_blur` cuối cùng mà
// sau đó không có `form_submit` chính là ô khiến họ rời đi.
//
// KHÔNG BAO GIỜ ghi giá trị người dùng nhập. Chỉ ghi tên ô, loại ô, có điền
// hay không, và bao lâu. Một field tên "password" hay "cvv" mà lọt giá trị ra
// event là sự cố bảo mật, không phải lỗi phân tích — nên chặn ở tầng thiết kế
// chứ không dựa vào người tích hợp nhớ tắt.

import type { CapturePlugin, EventName, EventProperties } from '../types';

type Emit = (name: EventName, props: EventProperties) => void;

export interface FormTrackingOptions {
  /** Bỏ qua field khớp selector này (ngoài các loại nhạy cảm đã chặn sẵn). */
  ignoreSelector?: string;
}

/** Loại input không bao giờ được đụng tới, kể cả metadata độ dài. */
const SENSITIVE_TYPES = new Set(['password', 'hidden']);
/** Tên/id gợi ý dữ liệu nhạy cảm — chặn theo linh cảm, thà thiếu còn hơn rò. */
const SENSITIVE_NAME = /pass|pwd|cvv|cvc|card|credit|ssn|secret|token|otp|pin/i;

function fieldName(el: HTMLElement): string {
  return el.getAttribute('data-track-id')
      || el.getAttribute('name')
      || el.id
      || el.getAttribute('aria-label')
      || el.getAttribute('placeholder')
      || el.tagName.toLowerCase();
}

function formName(el: HTMLElement): string {
  const form = el.closest('form');
  if (!form) return '(no form)';
  return form.getAttribute('data-track-id') || form.getAttribute('name') || form.id || 'form';
}

function isSensitive(el: HTMLElement): boolean {
  const type = (el as HTMLInputElement).type || '';
  if (SENSITIVE_TYPES.has(type)) return true;
  const name = `${el.getAttribute('name') || ''} ${el.id || ''} ${el.getAttribute('autocomplete') || ''}`;
  return SENSITIVE_NAME.test(name);
}

export function formTrackingPlugin(opts: FormTrackingOptions = {}): CapturePlugin {
  return {
    name: 'FormTracking',
    install(emit: Emit) {
      const focusedAt = new WeakMap<HTMLElement, number>();
      const changed = new WeakSet<HTMLElement>();

      const isField = (el: EventTarget | null): el is HTMLElement => {
        if (!(el instanceof HTMLElement)) return false;
        const tag = el.tagName.toLowerCase();
        if (tag !== 'input' && tag !== 'select' && tag !== 'textarea') return false;
        if (isSensitive(el)) return false;
        if (opts.ignoreSelector && el.matches(opts.ignoreSelector)) return false;
        return true;
      };

      const onFocus = (ev: FocusEvent) => {
        if (!isField(ev.target)) return;
        focusedAt.set(ev.target, Date.now());
        emit('form_field_focus', {
          form: formName(ev.target),
          field: fieldName(ev.target),
          field_type: (ev.target as HTMLInputElement).type || ev.target.tagName.toLowerCase(),
        });
      };

      const onBlur = (ev: FocusEvent) => {
        if (!isField(ev.target)) return;
        const el = ev.target;
        const t0 = focusedAt.get(el);
        const value = (el as HTMLInputElement).value ?? '';
        emit('form_field_blur', {
          form: formName(el),
          field: fieldName(el),
          // Chỉ CÓ/KHÔNG và độ dài — không bao giờ là nội dung.
          filled: value.length > 0,
          length: value.length,
          changed: changed.has(el),
          duration_ms: t0 ? Date.now() - t0 : undefined,
        });
      };

      const onChange = (ev: Event) => {
        if (!isField(ev.target)) return;
        changed.add(ev.target);
      };

      const onSubmit = (ev: Event) => {
        const form = ev.target;
        if (!(form instanceof HTMLFormElement)) return;
        const fields = Array.from(form.elements).filter(isField);
        emit('form_submit', {
          form: formName(form),
          field_count: fields.length,
          filled_count: fields.filter((f) => ((f as HTMLInputElement).value || '').length > 0).length,
        });
      };

      // capture: true — focus/blur không nổi bọt, và bắt trước khi app gọi
      // stopPropagation trên submit.
      document.addEventListener('focus', onFocus, true);
      document.addEventListener('blur', onBlur, true);
      document.addEventListener('change', onChange, true);
      document.addEventListener('submit', onSubmit, true);

      return () => {
        document.removeEventListener('focus', onFocus, true);
        document.removeEventListener('blur', onBlur, true);
        document.removeEventListener('change', onChange, true);
        document.removeEventListener('submit', onSubmit, true);
      };
    },
  };
}
