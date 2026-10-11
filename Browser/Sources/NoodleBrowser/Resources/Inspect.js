const clip = (s,n=300) => String(s || '').slice(0,n);
const selector = e => {
  if(e.id) return '#'+CSS.escape(e.id);
  const parts=[];
  while(e && e.nodeType===1 && parts.length<12) {
    let p=e.localName;
    const same=e.parentElement ? [...e.parentElement.children].filter(x=>x.localName===p) : [];
    if(same.length>1) p+=':nth-of-type('+(same.indexOf(e)+1)+')';
    parts.unshift(p); e=e.parentElement;
  }
  return parts.join(' > ');
};
const interactive = {a:1,button:1,input:1,textarea:1,select:1,iframe:1};
let order=0;
const scored=[...document.querySelectorAll('a,button,input,textarea,select,[role="button"],[role="link"],[contenteditable="true"],iframe')].slice(0,300).map(e=>{
 const r=e.getBoundingClientRect();
 const label = clip(e.getAttribute('aria-label')||e.labels?.[0]?.innerText||e.innerText||e.getAttribute('placeholder')||e.getAttribute('title'));
 const visible = !!(r.width&&r.height);
 // Relevance from the document itself: what a task can act on comes first, so a
 // cap keeps the useful elements instead of whichever the DOM listed first.
 let score = 0;
 if(visible) score += 2;
 if(label) score += 2;
 if(interactive[e.localName] || e.getAttribute('role')) score += 1;
 if(e.disabled) score -= 2;
 if(r.y >= 0 && r.y <= innerHeight) score += 1;
 return {score, index: order++, target:selector(e),tag:e.localName,type:e.type||undefined,
  label,visible,disabled:!!e.disabled,
  href:e.localName==='a'?e.href:undefined,
  value:e.type==='password'||e.type==='file'?undefined:clip(e.value),
  rect:{x:r.x,y:r.y,width:r.width,height:r.height}};
}).sort((a,b)=>b.score-a.score||a.index-b.index)
 .map(({score,index,...e},i)=>({rank:i+1,...e}));
return {url:location.href,title:document.title,readyState:document.readyState,
 text:clip(document.body?.innerText,30000),elements:scored,viewport:{width:innerWidth,height:innerHeight}};
