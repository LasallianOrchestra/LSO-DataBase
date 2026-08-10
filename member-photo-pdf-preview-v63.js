(() => {
  'use strict';

  const MAX_INPUT_BYTES = 5 * 1024 * 1024;
  const MAX_DATA_URL_CHARS = 120_000; // ~90 KB binary: enough for a sharp 2x2 PDF portrait without bloating shared records
  const TARGET_SIZES = [512, 448, 384, 320];
  const QUALITIES = [0.90, 0.86, 0.82, 0.78, 0.72];
  let activePdf = null;

  const el = (id) => document.getElementById(id);
  const safe = (value) => String(value ?? '').replace(/[&<>'"]/g, (ch) => ({ '&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;' }[ch]));

  function initials(name) {
    return String(name || 'LSO').trim().split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join('').toUpperCase() || 'LSO';
  }

  function photoValue() {
    return String(el('memberProfilePhotoData')?.value || '');
  }

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
        ? 'Legacy low-resolution photo detected — re-upload the original image for a sharper 2×2 PDF portrait.'
        : 'High-quality profile photo ready to save.');
    } else {
      preview.innerHTML = `<span>${safe(initials(name))}</span>`;
      preview.classList.remove('has-photo');
      remove?.classList.add('hidden');
      if (status) status.textContent = statusText || 'JPEG, PNG, or WebP • up to 5 MB';
    }
  }

  function loadImage(file) {
    // Use HTMLImageElement for the widest CanvasRenderingContext2D compatibility.
    // Some browsers expose createImageBitmap() but return an object that cannot be
    // passed reliably to drawImage(), causing "Overload resolution failed".
    return new Promise((resolve, reject) => {
      const url = URL.createObjectURL(file);
      const image = new Image();
      let settled = false;
      const cleanupOnError = (message) => {
        if (settled) return;
        settled = true;
        URL.revokeObjectURL(url);
        reject(new Error(message || 'The selected image could not be read.'));
      };
      image.onload = () => {
        if (settled) return;
        const width = Number(image.naturalWidth || image.width || 0);
        const height = Number(image.naturalHeight || image.height || 0);
        if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
          cleanupOnError('The selected image has invalid dimensions.');
          return;
        }
        settled = true;
        resolve({
          width,
          height,
          element: image,
          close() { URL.revokeObjectURL(url); }
        });
      };
      image.onerror = () => cleanupOnError('The selected image could not be decoded by this browser.');
      image.decoding = 'async';
      image.src = url;
    });
  }

  async function compressPhoto(file) {
    if (!file || !/^image\/(jpeg|png|webp)$/i.test(file.type || '')) throw new Error('Choose a JPEG, PNG, or WebP image.');
    if (file.size > MAX_INPUT_BYTES) throw new Error('The photo is larger than 5 MB. Choose a smaller image.');
    const source = await loadImage(file);
    try {
      if (!source.width || !source.height) throw new Error('The selected image has invalid dimensions.');
      const square = Math.min(source.width, source.height);
      const sx = Math.max(0, (source.width - square) / 2);
      const sy = Math.max(0, (source.height - square) / 2);
      for (const size of TARGET_SIZES) {
        const canvas = document.createElement('canvas');
        canvas.width = size;
        canvas.height = size;
        const ctx = canvas.getContext('2d', { alpha: false });
        if (!ctx) throw new Error('This browser cannot optimize the photo.');
        ctx.fillStyle = '#ffffff';
        ctx.fillRect(0, 0, size, size);
        ctx.imageSmoothingEnabled = true;
        try { ctx.imageSmoothingQuality = 'high'; } catch {}
        // Draw with the simpler five-argument overload and let the canvas clip the
        // centered overflow. This avoids browser-specific failures in the nine-argument
        // drawImage overload while preserving the square center crop.
        const scale = size / square;
        const drawWidth = Math.max(1, Math.round(source.width * scale));
        const drawHeight = Math.max(1, Math.round(source.height * scale));
        const drawX = Math.round((size - drawWidth) / 2);
        const drawY = Math.round((size - drawHeight) / 2);
        if (!(source.element instanceof HTMLImageElement)) throw new Error('The photo decoder returned an unsupported image source.');
        try {
          ctx.drawImage(source.element, drawX, drawY, drawWidth, drawHeight);
        } catch (error) {
          console.error('Canvas photo draw failed:', error);
          throw new Error('This browser could not prepare the selected photo. Try saving the image as JPEG or PNG and upload it again.');
        }
        for (const quality of QUALITIES) {
          const dataUrl = canvas.toDataURL('image/jpeg', quality);
          if (dataUrl.length <= MAX_DATA_URL_CHARS) return dataUrl;
        }
      }
      throw new Error('The photo could not be reduced to a safe profile size. Try a simpler or smaller photo.');
    } finally {
      source.close?.();
    }
  }

  async function handlePhotoInput(event) {
    const input = event.currentTarget;
    const file = input.files?.[0];
    if (!file) return;
    const status = el('memberPhotoStatus');
    const uploadLabel = document.querySelector('label[for="memberPhotoInput"]');
    try {
      input.disabled = true;
      uploadLabel?.classList.add('is-busy');
      if (status) status.textContent = 'Preparing a high-quality profile photo…';
      const dataUrl = await compressPhoto(file);
      if (el('memberProfilePhotoData')) el('memberProfilePhotoData').value = dataUrl;
      renderPhotoEditor(`High-quality photo ready • approximately ${Math.max(1, Math.round(dataUrl.length * 0.75 / 1024))} KB.`);
    } catch (error) {
      console.error('Member photo processing failed:', error);
      renderPhotoEditor(error.message || 'Unable to process the selected photo.');
      window.LSOApp?.showToast?.(error.message || 'Unable to process the selected photo.', true);
    } finally {
      input.value = '';
      input.disabled = false;
      uploadLabel?.classList.remove('is-busy');
    }
  }

  function removePhoto() {
    const hidden = el('memberProfilePhotoData');
    if (!hidden) return;
    hidden.value = '';
    renderPhotoEditor('Profile photo will be removed when you save the member record.');
  }

  function ensurePdfDialog() {
    if (el('memberPdfPreviewDialog')) return el('memberPdfPreviewDialog');
    const shell = document.createElement('div');
    shell.innerHTML = `
      <div class="member-pdf-preview-backdrop hidden" id="memberPdfPreviewDialog" role="dialog" aria-modal="true" aria-labelledby="memberPdfPreviewTitle" hidden>
        <div class="member-pdf-preview-card">
          <header class="member-pdf-preview-header">
            <div><p class="eyebrow">Members Overall Record</p><h2 id="memberPdfPreviewTitle">PDF Preview</h2><p id="memberPdfPreviewMeta">Review the official document before downloading.</p></div>
            <button class="icon-button" id="closeMemberPdfPreview" type="button" aria-label="Close PDF preview">×</button>
          </header>
          <div class="member-pdf-preview-body">
            <iframe id="memberPdfPreviewFrame" title="Members Overall Record PDF preview"></iframe>
            <div class="member-pdf-preview-fallback"><strong>Preview not visible?</strong><span>Some mobile browsers open PDFs in their own viewer.</span><button class="button button-secondary" id="openMemberPdfPreviewTab" type="button">Open Full Preview</button></div>
          </div>
          <footer class="member-pdf-preview-footer">
            <small>Downloading creates the same reviewed PDF shown above.</small>
            <div class="inline-actions"><button class="button button-secondary" id="cancelMemberPdfPreview" type="button">Close</button><button class="button button-primary" id="downloadMemberPdfPreview" type="button">Download PDF</button></div>
          </footer>
        </div>
      </div>`;
    const dialog = shell.firstElementChild;
    document.body.appendChild(dialog);
    const close = () => closePdfPreview();
    el('closeMemberPdfPreview')?.addEventListener('click', close);
    el('cancelMemberPdfPreview')?.addEventListener('click', close);
    dialog.addEventListener('click', (event) => { if (event.target === dialog) close(); });
    el('openMemberPdfPreviewTab')?.addEventListener('click', () => {
      if (!activePdf?.url) return;
      const opened = window.open(activePdf.url, '_blank', 'noopener,noreferrer');
      if (!opened) window.LSOApp?.showToast?.('Allow pop-ups to open the full PDF preview.', true);
    });
    el('downloadMemberPdfPreview')?.addEventListener('click', () => {
      if (!activePdf?.url) return;
      const link = document.createElement('a');
      link.href = activePdf.url;
      link.download = activePdf.filename;
      document.body.appendChild(link);
      link.click();
      link.remove();
      activePdf.onDownload?.();
      window.LSOApp?.showToast?.('Members Overall Record PDF downloaded.');
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && !dialog.hidden) closePdfPreview();
    });
    return dialog;
  }

  function closePdfPreview() {
    const dialog = el('memberPdfPreviewDialog');
    if (dialog) {
      dialog.classList.add('hidden');
      dialog.hidden = true;
      dialog.setAttribute('aria-hidden', 'true');
    }
    const frame = el('memberPdfPreviewFrame');
    if (frame) frame.removeAttribute('src');
    if (activePdf?.url) URL.revokeObjectURL(activePdf.url);
    activePdf = null;
    document.body.classList.remove('member-pdf-preview-open');
  }

  function openPdfPreview({ blob, filename, memberName, onDownload }) {
    if (!(blob instanceof Blob)) throw new Error('A valid PDF preview was not generated.');
    closePdfPreview();
    const dialog = ensurePdfDialog();
    const url = URL.createObjectURL(blob);
    activePdf = { blob, filename: filename || 'LSO_Members_Overall_Record.pdf', memberName: memberName || 'Member', onDownload, url };
    if (el('memberPdfPreviewTitle')) el('memberPdfPreviewTitle').textContent = `${activePdf.memberName} — PDF Preview`;
    if (el('memberPdfPreviewMeta')) el('memberPdfPreviewMeta').textContent = 'Review the official LSO header, footer, profile, attendance, reports, and duty-hour records before downloading.';
    const frame = el('memberPdfPreviewFrame');
    if (frame) frame.src = `${url}#toolbar=1&navpanes=0&view=FitH`;
    dialog.hidden = false;
    dialog.classList.remove('hidden');
    dialog.setAttribute('aria-hidden', 'false');
    document.body.classList.add('member-pdf-preview-open');
    setTimeout(() => el('closeMemberPdfPreview')?.focus(), 20);
  }

  function initializePhotoEditor() {
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

  window.LSOMemberPdfPreview = Object.freeze({ open: openPdfPreview, close: closePdfPreview });
  window.LSOMemberPhotoV64 = Object.freeze({ compressPhoto, refreshEditor: renderPhotoEditor });
  // Backward-compatible alias for any V63 code that may still reference the helper.
  window.LSOMemberPhotoV63 = window.LSOMemberPhotoV64;
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initializePhotoEditor, { once: true });
  else initializePhotoEditor();
})();
