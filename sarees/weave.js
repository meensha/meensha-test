// Live product grid for the static /sarees/<slug>/ pages. Same data and
// same substring match as the homepage's ?shop=<term> (matchSearch in
// index.html), so a weave page lists exactly what ?shop= would.
(async function () {
  const SB = 'https://eglanmhhcccsuhbxywua.supabase.co';
  const SK = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVnbGFubWhoY2Njc3VoYnh5d3VhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ4Nzc2MDQsImV4cCI6MjA5MDQ1MzYwNH0.0qjzkMVVajqMkx7SM-hhd6J62zVVFduVDbdr6juiNgo';
  const g = document.getElementById('wv-grid');
  if (!g) return;
  const term = (g.dataset.term || '').toLowerCase();
  const get = t => fetch(`${SB}/rest/v1/${t}`, { headers: { apikey: SK, Authorization: 'Bearer ' + SK } }).then(r => r.ok ? r.json() : []);
  let au = false;
  try { au = localStorage.getItem('msh_currency') === 'AU'; } catch (e) {}
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  try {
    const [skus, units] = await Promise.all([
      get('public_skus?select=id,name,display_material,display_variant,pattern,photos,sale_price,mrp,sale_price_aud,india_available,au_available&order=sku_code'),
      get('public_units?select=sku_id,status&status=eq.available'),
    ]);
    const avail = {};
    units.forEach(u => { avail[u.sku_id] = (avail[u.sku_id] || 0) + 1; });
    const items = skus.filter(it => avail[it.id] > 0 &&
      [it.name, it.display_variant, it.display_material, it.pattern].join(' ').toLowerCase().includes(term) &&
      (au ? it.au_available : it.india_available));
    if (!items.length) {
      g.innerHTML = '<p class="wv-empty">Nothing in stock right now. <a href="https://wa.me/918709525218">Message us on WhatsApp</a> and we\'ll source one for you.</p>';
      return;
    }
    g.innerHTML = items.map(it => {
      const nm = it.name + (it.display_variant && it.display_variant !== '-' ? ' (' + it.display_variant + ')' : '');
      const alt = nm + (it.display_material ? ' – ' + it.display_material : '');
      const price = au ? 'A$' + Number(it.sale_price_aud || 0).toLocaleString('en-AU') : '₹' + Number(it.sale_price || it.mrp || 0).toLocaleString('en-IN');
      const ph = (it.photos || [])[0];
      return `<a class="wv-item" href="../../product.html?id=${encodeURIComponent(it.id)}">
        <div class="wv-img">${ph ? `<img src="${esc(ph)}" alt="${esc(alt)}" loading="lazy" decoding="async">` : '<span>🧵</span>'}</div>
        <div class="wv-nm">${esc(nm)}</div><div class="wv-fab">${esc(it.display_material || '')}</div><div class="wv-pr">${price}</div></a>`;
    }).join('');
  } catch (e) {
    g.innerHTML = '<p class="wv-empty">Couldn\'t load pieces right now. Please try again shortly.</p>';
  }
})();
