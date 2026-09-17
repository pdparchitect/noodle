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
const elements=[...document.querySelectorAll('a,button,input,textarea,select,[role="button"],[role="link"],[contenteditable="true"],iframe')].slice(0,300).map(e=>{
 const r=e.getBoundingClientRect();
 return {target:selector(e),tag:e.localName,type:e.type||undefined,
  label:clip(e.getAttribute('aria-label')||e.labels?.[0]?.innerText||e.innerText||e.getAttribute('placeholder')||e.getAttribute('title')),
  visible:!!(r.width&&r.height),disabled:!!e.disabled,
  href:e.localName==='a'?e.href:undefined,
  value:e.type==='password'||e.type==='file'?undefined:clip(e.value),
  rect:{x:r.x,y:r.y,width:r.width,height:r.height}};
});
return {url:location.href,title:document.title,readyState:document.readyState,
 text:clip(document.body?.innerText,30000),elements,viewport:{width:innerWidth,height:innerHeight}};
