// Wire .copy buttons trong .code-block: copy code block bên dưới vào clipboard.
document.querySelectorAll('.code-block .copy').forEach(btn => {
  btn.addEventListener('click', async () => {
    const block = btn.closest('.code-block');
    if (!block) return;
    const code = block.querySelector('pre code') || block.querySelector('pre');
    if (!code) return;
    try {
      await navigator.clipboard.writeText(code.textContent);
      const orig = btn.textContent;
      btn.textContent = '✓ Đã copy';
      btn.classList.add('ok');
      setTimeout(() => { btn.textContent = orig; btn.classList.remove('ok'); }, 1400);
    } catch (e) {
      btn.textContent = '✗ Lỗi';
      setTimeout(() => { btn.textContent = '📋 Copy'; }, 1400);
    }
  });
});
