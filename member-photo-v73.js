(() => {
  'use strict';

  const MAX_INPUT_BYTES = 5 * 1024 * 1024;
  const MAX_DATA_URL_CHARS = 120_000;
  const TARGET_SIZES = [512, 448, 384, 320];
  const QUALITIES = [0.90, 0.86, 0.82, 0.78, 0.72];
  const el = (id) => document.getElementById(id);
  const safe = (value) => String(value ?? '').replace(/[&<>'"]/g, (ch) => ({ '&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;' }[ch]));

  function initials(name) {
    return String(name || 'LSO').trim().split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join('').toUpperCase() || 'LSO';
  }
  function photoValue() { return String(el('memberProfilePhotoData')?.value || ''); }
  function renderPhotoEditor(statusText = '') {
    const preview = el('memberPhotoPreview');
    const hidden = el('memberProfilePhotoData');
    const status = el('memberPhotoStatus');
    const remove = el('removeMemberPhotoButton');
    if (!preview || !hidden) return;
    const dataUrl = String(hidden.value || '');
    const name = el('fullName')?.value || '';
    if (/^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(dataUrl)) {
      preview.innerHTML = `<img src="${safe(dataUrl)}" alt="Member profile photo" decoding="async"/>`;
      preview.classList.add('has-photo');
      remove?.classList.remove('hidden');
      if (status) status.textContent = statusText || (dataUrl.length < 24_000
        ? 'Legacy low-resolution photo detected — re-upload the original image for a sharper profile photo.'
        : 'High-quality profile photo ready to save.');
    } else {
      preview.innerHTML = `<span>${safe(initials(name))}</span>`;
      preview.classList.remove('has-photo');
      remove?.classList.add('hidden');
      if (status) status.textContent = statusText || 'JPEG, PNG, or WebP • up to 5 MB';
    }
  }
  function loadImage(file) {
    return new Promise((resolve, reject) => {
      const url = URL.createObjectURL(file);
      const image = new Image();
      let settled = false;
      const fail = (message) => {
        if (settled) return;
        settled = true;
        URL.revokeObjectURL(url);
        reject(new Error(message || 'The selected image could not be read.'));
      };
      image.onload = () => {
        if (settled) return;
        const width = Number(image.naturalWidth || image.width || 0);
        const height = Number(image.naturalHeight || image.height || 0);
        if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) return fail('The selected image has invalid dimensions.');
        settled = true;
        resolve({ width, height, element: image, close() { URL.revokeObjectURL(url); } });
      };
      image.onerror = () => fail('The selected image could not be decoded by this browser.');
      image.decoding = 'async';
      image.src = url;
    });
  }
  async function compressPhoto(file) {
    if (!file || !/^image\/(jpeg|png|webp)$/i.test(file.type || '')) throw new Error('Choose a JPEG, PNG, or WebP image.');
    if (file.size > MAX_INPUT_BYTES) throw new Error('The photo is larger than 5 MB. Choose a smaller image.');
    const source = await loadImage(file);
    try {
      const square = Math.min(source.width, source.height);
      for (const size of TARGET_SIZES) {
        const canvas = document.createElement('canvas');
        canvas.width = size; canvas.height = size;
        const ctx = canvas.getContext('2d', { alpha: false });
        if (!ctx) throw new Error('This browser cannot optimize the photo.');
        ctx.fillStyle = '#ffffff'; ctx.fillRect(0, 0, size, size); ctx.imageSmoothingEnabled = true;
        try { ctx.imageSmoothingQuality = 'high'; } catch {}
        const scale = size / square;
        const drawWidth = Math.max(1, Math.round(source.width * scale));
        const drawHeight = Math.max(1, Math.round(source.height * scale));
        const drawX = Math.round((size - drawWidth) / 2);
        const drawY = Math.round((size - drawHeight) / 2);
        try { ctx.drawImage(source.element, drawX, drawY, drawWidth, drawHeight); }
        catch (error) { console.error('Canvas photo draw failed:', error); throw new Error('This browser could not prepare the selected photo. Try JPEG or PNG.'); }
        for (const quality of QUALITIES) {
          const dataUrl = canvas.toDataURL('image/jpeg', quality);
          if (dataUrl.length <= MAX_DATA_URL_CHARS) return dataUrl;
        }
      }
      throw new Error('The photo could not be reduced to a safe profile size. Try a simpler or smaller photo.');
    } finally { source.close?.(); }
  }
  async function handlePhotoInput(event) {
    const input = event.currentTarget; const file = input.files?.[0]; if (!file) return;
    const status = el('memberPhotoStatus'); const uploadLabel = document.querySelector('label[for="memberPhotoInput"]');
    try {
      input.disabled = true; uploadLabel?.classList.add('is-busy'); if (status) status.textContent = 'Preparing a high-quality profile photo…';
      const dataUrl = await compressPhoto(file); if (el('memberProfilePhotoData')) el('memberProfilePhotoData').value = dataUrl;
      renderPhotoEditor(`High-quality photo ready • approximately ${Math.max(1, Math.round(dataUrl.length * 0.75 / 1024))} KB.`);
    } catch (error) {
      console.error('Member photo processing failed:', error); renderPhotoEditor(error.message || 'Unable to process the selected photo.');
      window.LSOApp?.showToast?.(error.message || 'Unable to process the selected photo.', true);
    } finally { input.value = ''; input.disabled = false; uploadLabel?.classList.remove('is-busy'); }
  }
  function removePhoto() {
    const hidden = el('memberProfilePhotoData'); if (!hidden) return; hidden.value = '';
    renderPhotoEditor('Profile photo will be removed when you save the member record.');
  }
  function initialize() {
    el('memberPhotoInput')?.addEventListener('change', handlePhotoInput);
    el('removeMemberPhotoButton')?.addEventListener('click', removePhoto);
    el('fullName')?.addEventListener('input', () => { if (!photoValue()) renderPhotoEditor(); });
    window.addEventListener('lso:member-photo-form-opened', (event) => {
      const detail = event.detail || {};
      if (el('memberProfilePhotoData')) el('memberProfilePhotoData').value = String(detail.profilePhoto || '');
      renderPhotoEditor();
    });
    renderPhotoEditor();
  }
  window.LSOMemberPhotoV73 = Object.freeze({ compressPhoto, refreshEditor: renderPhotoEditor });
  window.LSOMemberPhotoV64 = window.LSOMemberPhotoV73;
  window.LSOMemberPhotoV63 = window.LSOMemberPhotoV73;
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true }); else initialize();
})();
