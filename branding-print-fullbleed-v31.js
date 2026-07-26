(() => {
  'use strict';

  const assetUrl = (name) => new URL(name, document.baseURI || window.location.href).href;
  const escapeHtml = (value) => String(value ?? '').replace(/[&<>'\"]/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '\"': '&quot;'
  }[character]));

  const logoUrl = assetUrl('lso-logo.png');
  const markUrl = assetUrl('lso-mark.png');
  const officialTemplatePdfUrl = assetUrl('lso-official-template.pdf');
  const officialTemplateUrl = assetUrl('lso-official-template.png');
  const officialHeaderUrl = assetUrl('lso-official-header.png');
  const officialFooterUrl = assetUrl('lso-official-footer.png');

  /*
   * Print output is built as exact A4 portrait sheets. Each sheet contains the
   * complete official template edge-to-edge as a background image, while generated content
   * remains organized inside the safe white body area. JavaScript pagination
   * duplicates the sheet whenever the report is longer than one page.
   */
  const printCss = `
    @page{size:A4 portrait;margin:0}
    *{box-sizing:border-box}
    :root{--print-deep:#0b3d2e;--print-emerald:#146c43;--print-gold:#d4a017;--print-gold-soft:#fff4cc;--print-green-soft:#e9f3ed;--print-surface:#ffffff;--print-ink:#17211d;--print-muted:#52645c;--print-line:#3f5f53}
    html,body{margin:0!important;padding:0!important;background:#edf2ef!important;color:var(--print-ink)!important;font-family:Arial,Helvetica,sans-serif!important;line-height:1.34!important;-webkit-print-color-adjust:exact!important;print-color-adjust:exact!important}
    body{width:210mm;min-width:210mm;max-width:210mm}
    body.lso-print-landscape,body.lso-print-portrait{width:210mm!important;min-width:210mm!important;max-width:210mm!important}
    body.lso-print-ready> :not(.lso-print-pages):not(script){display:none!important}
    .lso-official-template-header,.lso-official-template-footer{display:none!important}
    .lso-print-pages{display:block;width:210mm;margin:0!important;padding:0!important}
    .lso-print-page{position:relative;width:210mm;height:297mm;margin:0!important;padding:0!important;background:#fff;overflow:hidden;break-after:page;page-break-after:always;box-shadow:none!important}
    body.lso-print-landscape .lso-print-pages,body.lso-print-portrait .lso-print-pages{width:210mm!important}
    body.lso-print-landscape .lso-print-page,body.lso-print-portrait .lso-print-page{width:210mm!important;height:297mm!important}
    body.lso-print-landscape .lso-page-template,body.lso-print-portrait .lso-page-template{display:block!important;width:210mm!important;height:297mm!important;object-fit:fill!important}
    body.lso-print-landscape .lso-page-content,body.lso-print-portrait .lso-page-content{left:12mm!important;right:12mm!important;top:48mm!important;bottom:30mm!important}
    .lso-print-page:last-child{break-after:auto;page-break-after:auto}
    .lso-page-template{position:absolute!important;inset:0!important;width:210mm!important;height:297mm!important;max-width:none!important;max-height:none!important;margin:0!important;padding:0!important;object-fit:fill!important;display:block!important;z-index:0;pointer-events:none;-webkit-print-color-adjust:exact!important;print-color-adjust:exact!important}
    .lso-page-content{position:absolute;left:12mm;right:12mm;top:48mm;bottom:30mm;z-index:1;overflow:hidden}

    /* Centralized official document heading */
    .lso-document-heading{display:block!important;text-align:center!important;border-top:1.1mm solid var(--print-deep)!important;border-bottom:.65mm solid var(--print-gold)!important;padding:2.3mm 3mm 2.5mm!important;margin:0 0 4mm!important;background:linear-gradient(180deg,#f7fbf8 0%,#fff 100%)!important;break-inside:avoid;page-break-inside:avoid}
    .lso-document-heading-main{min-width:0!important}
    .lso-document-heading h1{font-size:17px!important;line-height:1.15!important;margin:1mm 0!important;color:var(--print-deep)!important;letter-spacing:.01em!important;overflow-wrap:anywhere}
    .lso-document-subtitle{font-size:8.2px!important;color:#405f54!important;line-height:1.4!important;margin-top:1mm!important}
    .lso-document-meta{font-size:7.2px!important;color:#60766e!important;line-height:1.35!important;text-align:center!important;max-width:none!important;margin-top:1.2mm!important}
    .lso-document-badge{display:inline-block!important;margin-top:1.8mm!important;padding:1.2mm 2.8mm!important;border:.35mm solid #9fc9b4!important;border-radius:999px!important;background:var(--print-green-soft)!important;color:#0d5f3f!important;font-size:7.2px!important;font-weight:800!important}
    .lso-print-header,.lso-print-brand,.lso-print-copy,.lso-print-logo{all:unset}
    h1{font-size:17px!important;line-height:1.15!important;color:var(--print-deep)!important}
    h2{font-size:13px!important;color:var(--print-deep)!important}
    h3{font-size:11px!important;color:var(--print-deep)!important}

    /* Strong, centered summary blocks */
    .summary{display:grid!important;grid-template-columns:repeat(3,minmax(0,1fr))!important;gap:2mm!important;margin:3mm 0 4mm!important;break-inside:avoid!important;page-break-inside:avoid!important}
    .summary>div{padding:2.2mm 2mm!important;border:.35mm solid #8eb9a4!important;border-top:1mm solid var(--print-emerald)!important;border-radius:1.8mm!important;background:#f7fbf8!important;text-align:center!important;min-width:0!important}
    .summary span{display:block!important;font-size:6.4px!important;line-height:1.25!important;text-transform:uppercase!important;letter-spacing:.06em!important;color:#4b6259!important;font-weight:700!important;overflow-wrap:anywhere}
    .summary strong{display:block!important;font-size:11.5px!important;line-height:1.22!important;margin-top:1mm!important;color:var(--print-deep)!important;overflow-wrap:anywhere}

    /* High-visibility tables */
    table{width:100%!important;max-width:100%!important;table-layout:fixed!important;border-collapse:collapse!important;border:.55mm solid var(--print-deep)!important;font-size:7px!important;margin:2.8mm 0 0!important;background:#fff!important}
    thead{display:table-header-group!important}
    tfoot{display:table-footer-group!important}
    tr{break-inside:avoid!important;page-break-inside:avoid!important}
    th,td{border:.28mm solid #45665a!important;padding:1.55mm 1.65mm!important;line-height:1.28!important;overflow-wrap:anywhere!important;word-break:normal!important;hyphens:auto!important;vertical-align:middle!important}
    th{background:var(--print-deep)!important;color:#fff!important;font-size:6.45px!important;line-height:1.25!important;text-transform:uppercase!important;letter-spacing:.045em!important;text-align:center!important;font-weight:800!important}
    tbody tr:nth-child(odd) td{background:#fff!important}
    tbody tr:nth-child(even) td{background:#f0f6f2!important}
    tbody td{height:auto!important;min-height:6.4mm!important;text-align:center!important;color:var(--print-ink)!important}
    tbody td.lso-col-text,tbody td[data-print-align="left"]{text-align:left!important}
    tbody td.lso-col-key{font-weight:700!important;color:var(--print-deep)!important}
    tbody td.lso-col-status{font-weight:800!important}
    tbody tr:last-child td{border-bottom:.45mm solid var(--print-deep)!important}
    tbody tr.lso-total-row td,tfoot td,.total-row td{background:var(--print-gold-soft)!important;color:var(--print-deep)!important;font-weight:800!important;border-top:.55mm solid var(--print-gold)!important}
    .monthly-roster{font-size:6.65px!important}
    .monthly-roster th{font-size:5.95px!important}
    .monthly-roster td{padding:1.45mm 1.6mm!important;line-height:1.28!important;height:6.8mm!important}

    /* Portrait-first table density: preserve every column while keeping wide reports readable. */
    table.lso-cols-7,table.lso-cols-8{font-size:6.05px!important}
    table.lso-cols-7 th,table.lso-cols-8 th{font-size:5.55px!important;letter-spacing:.025em!important}
    table.lso-cols-7 th,table.lso-cols-7 td,table.lso-cols-8 th,table.lso-cols-8 td{padding:1.15mm 1.2mm!important;line-height:1.2!important}
    table.lso-cols-9,table.lso-cols-10plus{font-size:5.15px!important}
    table.lso-cols-9 th,table.lso-cols-10plus th{font-size:4.75px!important;letter-spacing:.012em!important}
    table.lso-cols-9 th,table.lso-cols-9 td,table.lso-cols-10plus th,table.lso-cols-10plus td{padding:.85mm .9mm!important;line-height:1.16!important}
    table.lso-cols-9 tbody td,table.lso-cols-10plus tbody td{min-height:5.3mm!important}
    table.lso-cols-10plus .muted{font-size:4.6px!important;line-height:1.1!important}
    table.lso-cols-10plus td.lso-col-text{font-size:4.9px!important}

    .grid{break-inside:auto!important;page-break-inside:auto!important}
    .field{min-height:0!important;padding:2.4mm!important;border-color:#8aa89b!important;break-inside:avoid!important;page-break-inside:avoid!important;text-align:center!important}
    .field:nth-child(4n+1),.field:nth-child(4n+2){background:#f4f8f6!important}
    .field span{font-size:6.4px!important;color:#50645c!important;font-weight:700!important}
    .field strong{display:block!important;font-size:8.2px!important;color:var(--print-deep)!important;overflow-wrap:anywhere!important;margin-top:.8mm!important}
    .notes{font-size:8px!important;min-height:0!important;line-height:1.55!important;border:.35mm solid #8aa89b!important;border-left:1.1mm solid var(--print-gold)!important;background:#fbfcfb!important;break-inside:avoid!important;page-break-inside:avoid!important}
    .notes>strong:first-child{color:var(--print-deep)!important;text-transform:uppercase!important;letter-spacing:.04em!important}
    .report-note{font-size:7px!important;line-height:1.45!important;padding:2mm!important;margin:2mm 0 3mm!important;background:#f6f8f5!important;border-left:.9mm solid var(--print-gold)!important;color:#445b52!important}
    .report-section,.section-title{break-after:avoid!important;page-break-after:avoid!important}
    .report-section,.section-title h2{color:var(--print-deep)!important;text-align:center!important}
    .section-title{margin:4mm 0 2mm!important;padding-bottom:1.5mm!important;border-bottom:.35mm solid #9bb9ac!important}
    .section-title h2{font-size:12px!important}
    .sign{display:flex!important;justify-content:space-between!important;gap:16mm!important;margin-top:11mm!important;break-inside:avoid!important;page-break-inside:avoid!important;font-size:8px!important;text-align:center!important}
    .sign div{flex:1 1 0!important;border-top:.35mm solid var(--print-deep)!important;padding-top:1.5mm!important;color:var(--print-deep)!important;font-weight:700!important}
    .footer,.foot{display:none!important}
    .page-break{break-before:page!important;page-break-before:always!important}
    img,svg{max-width:100%}
    @media print{
      html,body{width:210mm!important;min-width:210mm!important;margin:0!important;padding:0!important;background:#fff!important}
      body.lso-print-landscape,body.lso-print-portrait{width:210mm!important;min-width:210mm!important;max-width:210mm!important}
      .lso-print-pages{margin:0!important}
      .lso-print-page{margin:0!important;box-shadow:none!important}
      button,.no-print{display:none!important}
    }
  `;

  function printHeader({ title, subtitle = '', meta = '', badge = '' } = {}) {
    return `<section class="header head lso-document-heading">
      <div class="lso-document-heading-main">
        <h1>${escapeHtml(title)}</h1>
        ${subtitle ? `<div class="sub id lso-document-subtitle">${escapeHtml(subtitle)}</div>` : ''}
        ${badge ? `<span class="badge lso-document-badge">${escapeHtml(badge)}</span>` : ''}
      </div>
      ${meta ? `<div class="sub id lso-document-meta">${escapeHtml(meta)}</div>` : ''}
    </section>`;
  }

  const printRuntimeScript = `<script>
  (()=>{
    'use strict';
    const PORTRAIT_TEMPLATE_URL=${JSON.stringify(officialTemplateUrl)};
    const pxPerMm=()=>{const probe=document.createElement('div');probe.style.cssText='position:absolute;visibility:hidden;width:100mm;height:1mm';document.body.appendChild(probe);const value=probe.getBoundingClientRect().width/100;probe.remove();return value||3.7795275591};
    const normalizeHeader=(value)=>String(value||'').trim().replace(/\s+/g,' ').toUpperCase();
    const removeUnneededColumns=()=>{
      document.querySelectorAll('table').forEach((table)=>{
        const headerRow=table.querySelector(':scope > thead > tr');
        if(!headerRow)return;
        const hiddenIndexes=Array.from(headerRow.children).map((cell,index)=>cell.dataset.printHidden==='true'?index:-1).filter((index)=>index>=0);
        if(!hiddenIndexes.length)return;
        table.querySelectorAll('tr').forEach((row)=>{
          const cells=Array.from(row.children);
          hiddenIndexes.slice().sort((a,b)=>b-a).forEach((index)=>{if(cells[index])cells[index].remove();});
        });
      });
    };
    const decorateTables=()=>{
      const leftLabels=['NAME','MEMBER','DESCRIPTION','REMARKS','PURPOSE','BASIS','VENUE','ACTIVITY','COURSE','POSITION','INSTRUMENT','RECORDED BY','MEMBER/S APPROVED'];
      const statusLabels=['STATUS','VERIFICATION','WORKFLOW'];
      document.querySelectorAll('table').forEach((table)=>{
        table.classList.add('lso-print-table');
        const header=table.querySelector(':scope > thead > tr');
        if(!header)return;
        const labels=Array.from(header.children).map((cell)=>normalizeHeader(cell.textContent));
        const columnCount=labels.length;
        table.classList.add(columnCount>=10?'lso-cols-10plus':columnCount===9?'lso-cols-9':columnCount===8?'lso-cols-8':columnCount===7?'lso-cols-7':'lso-cols-standard');
        table.querySelectorAll(':scope > tbody > tr').forEach((row,rowIndex)=>{
          if(/TOTAL\s*:?/i.test(row.textContent||''))row.classList.add('lso-total-row');
          Array.from(row.children).forEach((cell,index)=>{
            const label=labels[index]||'';
            if(leftLabels.some((token)=>label.includes(token))){cell.classList.add('lso-col-text');cell.dataset.printAlign='left';}
            if(index===0)cell.classList.add('lso-col-key');
            if(statusLabels.some((token)=>label.includes(token)))cell.classList.add('lso-col-status');
          });
        });
      });
    };
    const directContent=()=>Array.from(document.body.children).filter((node)=>node.tagName!=='SCRIPT'&&!node.classList.contains('lso-print-pages')&&!node.classList.contains('lso-official-template-header')&&!node.classList.contains('lso-official-template-footer'));
    const makePage=(container)=>{const page=document.createElement('section');page.className='lso-print-page';const template=document.createElement('img');template.className='lso-page-template';template.alt='Official Lasallian Symphony Orchestra document template';template.src=PORTRAIT_TEMPLATE_URL;const content=document.createElement('div');content.className='lso-page-content';page.append(template,content);container.appendChild(page);return {page,content};};
    const overflows=(content)=>content.scrollHeight>content.clientHeight+1;
    const addSimple=(node,state,newPage)=>{const clone=node.cloneNode(true);state.content.appendChild(clone);if(overflows(state.content)&&state.content.children.length>1){clone.remove();state=newPage();state.content.appendChild(clone);}return state;};
    const cloneTableShell=(table)=>{const next=table.cloneNode(false);Array.from(table.children).forEach((child)=>{if(child.tagName==='COLGROUP'||child.tagName==='THEAD')next.appendChild(child.cloneNode(true));});const body=document.createElement('tbody');next.appendChild(body);return {table:next,body};};
    const addTable=(source,state,newPage)=>{
      const rows=Array.from(source.querySelectorAll(':scope > tbody > tr'));
      if(!rows.length)return addSimple(source,state,newPage);
      let shell=cloneTableShell(source);state.content.appendChild(shell.table);
      if(overflows(state.content)&&state.content.children.length>1){shell.table.remove();state=newPage();shell=cloneTableShell(source);state.content.appendChild(shell.table);}
      rows.forEach((row)=>{const clone=row.cloneNode(true);shell.body.appendChild(clone);if(overflows(state.content)&&shell.body.children.length>1){clone.remove();state=newPage();shell=cloneTableShell(source);state.content.appendChild(shell.table);shell.body.appendChild(clone);}});
      return state;
    };
    const paginate=()=>{
      removeUnneededColumns();
      decorateTables();
      const nodes=directContent();
      const pages=document.createElement('main');pages.className='lso-print-pages';
      document.body.appendChild(pages);
      let state=makePage(pages);
      const newPage=()=>makePage(pages);
      nodes.forEach((node)=>{
        if(node.classList.contains('page-break')){state=newPage();return;}
        state=node.tagName==='TABLE'?addTable(node,state,newPage):addSimple(node,state,newPage);
      });
      Array.from(pages.querySelectorAll('.lso-print-page')).forEach((page)=>{if(!page.querySelector('.lso-page-content')?.children.length)page.remove();});
      document.body.classList.add('lso-print-ready');
      document.title='';
      return Promise.all(Array.from(pages.querySelectorAll('img')).map((image)=>image.complete?Promise.resolve():new Promise((resolve)=>{image.onload=image.onerror=resolve;})));
    };
    const start=async()=>{try{if(document.fonts&&document.fonts.ready)await document.fonts.ready;await paginate();await new Promise((resolve)=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));window.print();}catch(error){console.error('LSO print preparation failed',error);window.print();}};
    if(document.readyState==='complete')start();else window.addEventListener('load',start,{once:true});
  })();
  <\/script>`;

  window.LSOBrand = Object.freeze({
    logoUrl,
    markUrl,
    officialTemplatePdfUrl,
    officialTemplateUrl,
    defaultPrintTemplatePdfUrl: officialTemplatePdfUrl,
    defaultPrintTemplateUrl: officialTemplateUrl,
    defaultLandscapeTemplatePdfUrl: officialTemplatePdfUrl,
    defaultLandscapeTemplateUrl: officialTemplateUrl,
    officialHeaderUrl,
    officialFooterUrl,
    printCss,
    printHeader,
    printRuntimeScript
  });
})();
