(() => {
  const send = body => window.webkit.messageHandlers.noodle.postMessage(body);
  const failure = error => String(error) + (error?.stack ? '\n' + error.stack : '');
  const text = value => { try { return value instanceof Error ? failure(value) : typeof value === 'string' ? value : JSON.stringify(value) ?? String(value); } catch { return String(value); } };
  for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
    const original = console[level].bind(console);
    console[level] = (...args) => { original(...args); send({operation:'log', level, text:args.map(text).join(' ')}).catch(()=>{}); };
  }
  window.addEventListener('error', e => send({operation:'log',level:'error',text:`${e.message} at ${e.filename}:${e.lineno}:${e.colno}\n${e.error?.stack || ''}`}).catch(()=>{}));
  window.addEventListener('unhandledrejection', e => send({operation:'log',level:'unhandledrejection',text:failure(e.reason)}).catch(()=>{}));
  // WebKit can redact cross-origin timer errors to "Script error". Capture the
  // actual exception at the callback boundary, then preserve normal propagation.
  for (const name of ['setTimeout', 'setInterval', 'requestAnimationFrame']) {
    const original = window[name].bind(window);
    window[name] = (callback, ...args) => original(typeof callback === 'function' ? function(...values) {
      try { return callback.apply(this, values); }
      catch (error) { send({operation:'log',level:'error',text:failure(error)}).catch(()=>{}); throw error; }
    } : callback, ...args);
  }
  document.addEventListener('pointerdown', event => {
    if (!event.isTrusted || event.button !== 0 || !(event.target instanceof Element)) return;
    if (event.target.closest('button,a,input,textarea,select,label,[role="button"],[contenteditable="true"]')) return;
    for (let element = event.target; element; element = element.parentElement) {
      const region = getComputedStyle(element).getPropertyValue('--noodle-app-region').trim();
      if (region === 'no-drag') return;
      if (region === 'drag') {
        event.preventDefault();
        send({operation:'dragWindow'}).catch(error=>console.warn('Window drag failed:', String(error)));
        return;
      }
    }
  }, {capture:true});
  const browserFetch = window.fetch.bind(window);
  const nativeFetch = async (input, init) => {
    const request = new Request(input, init);
    if (!/^https?:$/.test(new URL(request.url).protocol)) return browserFetch(request);
    if (request.signal.aborted) throw new DOMException('Request aborted', 'AbortError');
    const id = crypto.randomUUID();
    const bytes = request.body ? new Uint8Array(await request.arrayBuffer()) : null;
    if (bytes && bytes.length > 16 * 1048576) throw new RangeError('Request body exceeds 16 MiB');
    let encoded = null;
    if (bytes) {
      let binary = '';
      for (let i = 0; i < bytes.length; i += 32768) binary += String.fromCharCode(...bytes.subarray(i, i + 32768));
      encoded = btoa(binary);
    }
    if (request.signal.aborted) throw new DOMException('Request aborted', 'AbortError');
    const abort = () => send({operation:'cancelFetch', id}).catch(()=>{});
    request.signal.addEventListener('abort', abort, {once:true});
    try {
      const reply = await send({operation:'fetch', id, url:request.url, method:request.method,
        headers:Object.fromEntries(request.headers), body:encoded, redirect:request.redirect});
      if (request.signal.aborted) throw new DOMException('Request aborted', 'AbortError');
      const data = Uint8Array.from(atob(reply.body), c=>c.charCodeAt(0));
      const response = new Response(request.method === 'HEAD' || [204,205,304].includes(reply.status) ? null : data,
        {status:reply.status, headers:reply.headers});
      Object.defineProperties(response, {url:{value:reply.url},redirected:{value:reply.redirected}});
      return response;
    } catch(error) {
      if (request.signal.aborted) throw new DOMException('Request aborted', 'AbortError');
      throw new TypeError(String(error));
    } finally { request.signal.removeEventListener('abort', abort); }
  };
  window.fetch = nativeFetch;
  const key = key => 'storage/' + encodeURIComponent(String(key)) + '.json';
  Object.defineProperty(window, 'noodle', {value:Object.freeze({
    version:1,
    fetch:nativeFetch,
    data:Object.freeze({readText:path=>send({operation:'read',path}),writeText:(path,text)=>send({operation:'write',path,text})}),
    storage:Object.freeze({get:async name=>{const value=await send({operation:'read',path:key(name)});return value===null?null:JSON.parse(value);},set:(name,value)=>send({operation:'write',path:key(name),text:JSON.stringify(value)})}),
    files:Object.freeze({openText:()=>send({operation:'openFile'}),saveText:(name,text)=>send({operation:'saveFile',name,text})})
  }), writable:false});
  window.__noodletControl = async r => {
    const rect = e => {const b=e.getBoundingClientRect();return {x:b.x,y:b.y,width:b.width,height:b.height};};
    if(r.operation==='inspect') return {title:document.title,url:location.href,viewport:{width:innerWidth,height:innerHeight},text:document.body?.innerText.slice(0,20000),elements:[...document.querySelectorAll('button,input,textarea,select,a,[role],[contenteditable],canvas')].slice(0,500).map((e,i)=>{e.dataset.noodletId=String(i);return {target:`[data-noodlet-id="${i}"]`,tag:e.tagName,role:e.getAttribute('role'),name:e.getAttribute('aria-label')||e.getAttribute('placeholder')||e.innerText?.slice(0,160),value:e.value,disabled:!!e.disabled,rect:rect(e)};})};
    const e = r.target ? document.querySelector(r.target) : (r.x!==undefined && r.y!==undefined ? document.elementFromPoint(r.x,r.y) : document.activeElement);
    if(!e) throw Error('No element matches the target. Inspect the current page first.');
    const b=e.getBoundingClientRect(), x=r.x??b.x+b.width/2,y=r.y??b.y+b.height/2;
    const mouse=(type,x,y,buttons=0)=>e.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,clientX:x,clientY:y,button:0,buttons}));
    const pointer=(type,x,y,buttons=0)=>e.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,clientX:x,clientY:y,button:0,buttons,pointerId:1,pointerType:'mouse',isPrimary:true}));
    if(r.operation==='click') { e.focus();pointer('pointerdown',x,y,1);mouse('mousedown',x,y,1);pointer('pointerup',x,y);mouse('mouseup',x,y); if(typeof e.click==='function')e.click();else mouse('click',x,y); }
    else if(r.operation==='type') { e.focus();if('value' in e){const setter=Object.getOwnPropertyDescriptor(e instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:HTMLInputElement.prototype,'value')?.set;if(setter)setter.call(e,r.text??'');else e.value=r.text??'';}else if(e.isContentEditable)e.textContent=r.text??'';else throw Error('Target is not editable.');e.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:r.text??''}));e.dispatchEvent(new Event('change',{bubbles:true})); }
    else if(r.operation==='key') {e.focus();const key=r.text??'Enter';e.dispatchEvent(new KeyboardEvent('keydown',{key,code:key,bubbles:true}));e.dispatchEvent(new KeyboardEvent('keyup',{key,code:key,bubbles:true}));}
    else if(r.operation==='scroll') { const target=r.target?e:window;target.scrollBy({left:r.toX??0,top:r.toY??300,behavior:'instant'}); }
    else if(r.operation==='drag') {pointer('pointerdown',x,y,1);mouse('mousedown',x,y,1);for(let i=1;i<=12;i++){const px=x+((r.toX??x)-x)*i/12,py=y+((r.toY??y)-y)*i/12;pointer('pointermove',px,py,1);mouse('mousemove',px,py,1);}pointer('pointerup',r.toX??x,r.toY??y);mouse('mouseup',r.toX??x,r.toY??y);}
    else throw Error('Unsupported web operation: '+r.operation);
    return {ok:true,synthetic:true};
  };
})();
