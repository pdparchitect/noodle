const clip = (s, n = 300) => String(s || '').slice(0, n);
const visible = e => {
  if (!e.isConnected) return false;
  const r = e.getBoundingClientRect();
  if (!r.width || !r.height) return false;
  const s = getComputedStyle(e);
  return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
};
// Count DOM churn over a short window after the action: a settling page goes quiet.
const mutations = await new Promise(resolve => {
  let count = 0;
  const mo = new MutationObserver(list => { count += list.length; });
  mo.observe(document.documentElement, { subtree: true, childList: true, attributes: true });
  setTimeout(() => { mo.disconnect(); resolve(count); }, 350);
});
const spinners = [...document.querySelectorAll('[role="progressbar"], [class*="spinner" i], [class*="loading" i], [class*="progress" i]')]
  .filter(visible).length;
const activeResources = performance.getEntriesByType('resource').filter(e => e.responseEnd === 0).length;
// The topmost page-covering overlay, with the blocker vocabulary it matches.
const area = innerWidth * innerHeight;
let overlay = null, overlayZ = -1;
// Uncapped is safe: the rect and 25%-area checks are the cheap path — the loop performs no writes, so layout flushes once and rect reads are cached — and only area-passing candidates reach getComputedStyle.
for (const e of [...document.querySelectorAll('dialog, [role="dialog"], [role="alertdialog"], div, section, aside')]) {
  const r = e.getBoundingClientRect();
  if (!r.width || !r.height) continue;
  if (r.width * r.height < area * 0.25) continue;
  const s = getComputedStyle(e);
  if (s.visibility === 'hidden' || s.display === 'none' || s.opacity === '0') continue;
  if (s.position !== 'fixed' && s.position !== 'absolute') continue;
  const z = Number(s.zIndex) || 0;
  if (z < overlayZ) continue;
  overlay = e; overlayZ = z;
}
let overlayText, overlayMatches;
if (overlay) {
  overlayText = clip(overlay.innerText || overlay.getAttribute('aria-label'));
  const hay = ((overlay.id || '') + ' ' + (overlay.className && overlay.className.baseVal !== undefined ? overlay.className.baseVal : overlay.className || '') + ' ' + overlayText).toLowerCase();
  const words = { cookie: ['cookie', 'consent', 'gdpr'], login: ['sign in', 'log in', 'sign up', 'create account'],
    captcha: ['captcha', 'robot', 'are you human', 'verify you'], paywall: ['subscribe', 'subscription', 'paywall', 'premium plan'],
    age: ['age verification', 'are you over 18', 'confirm your age'], download: ['download ', 'get the app'] };
  overlayMatches = Object.keys(words).filter(k => words[k].some(w => hay.includes(w)));
}
const element = target ? document.querySelector(target) : null;
return { url: location.href, title: document.title, readyState: document.readyState,
  spinners, mutations, activeResources,
  overlayText, overlayMatches,
  inputEcho: target && text !== undefined && element ? (element.value === text || element.textContent === text) : undefined,
  targetGone: target ? !document.querySelector(target) : undefined,
  urlChanged: previousURL ? location.href !== previousURL : undefined };
