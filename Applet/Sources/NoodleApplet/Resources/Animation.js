// Injected inside a closure with an explicit, host-selected `synthetic` boolean.
const nativeVisibility = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState').get;
const nativeNow = performance.now.bind(performance);
const nativeRAF = window.requestAnimationFrame.bind(window);
const nativeCancel = window.cancelAnimationFrame.bind(window);
const send = body => window.webkit.messageHandlers.noodle.postMessage(body);
let time = 0, nextID = 0, frameCount = 0, lastTimestamp = null, lastReport = -Infinity;
const pending = new Map();
const state = () => ({
  readyState: document.readyState,
  visibilityState: document.visibilityState,
  nativeVisibilityState: nativeVisibility.call(document),
  synthetic,
  animationFrameCount: frameCount,
  lastAnimationFrameTimestamp: lastTimestamp
});
const report = () => send({operation: 'rendering', state: state()}).catch(() => {});
const observed = timestamp => {
  if (lastTimestamp !== timestamp) { frameCount++; lastTimestamp = timestamp; }
  if (!synthetic && nativeNow() - lastReport >= 500) {
    lastReport = nativeNow();
    report();
  }
};
if (synthetic) {
  Object.defineProperties(document, {
    hidden: {get: () => false}, visibilityState: {get: () => 'visible'}
  });
  Object.defineProperty(performance, 'now', {value: () => time});
}
window.requestAnimationFrame = callback => {
  if (typeof callback !== 'function') throw new TypeError('Animation callback must be a function');
  if (synthetic) { const id = ++nextID; pending.set(id, callback); return id; }
  return nativeRAF(timestamp => { observed(timestamp); callback(timestamp); });
};
window.cancelAnimationFrame = id => synthetic ? pending.delete(Number(id)) : nativeCancel(id);
let stepping = false;
const step = async (frames = 1) => {
  if (!synthetic) throw new Error('Open with --mode headless --test-clock before stepping.');
  if (!Number.isInteger(frames) || frames < 1 || frames > 600) throw new RangeError('Use 1–600 frames.');
  if (stepping) throw new Error('A frame step is already in progress.');
  stepping = true;
  try {
    for (let frame = 0; frame < frames; frame++) {
      time += 1000 / 60;
      // New requests wait until the next frame; cancellation of a later callback
      // during this frame still works. Callback exceptions do not drop siblings.
      for (const id of [...pending.keys()]) {
        const callback = pending.get(id);
        if (!callback) continue;
        pending.delete(id);
        observed(time);
        try { callback(time); }
        catch (error) { await send({operation:'log',level:'error',text:String(error) + '\n' + (error?.stack || '')}).catch(() => {}); }
        await Promise.resolve();
      }
    }
    await report();
    return {synthetic:true, frames, timeMilliseconds:time, pendingAnimationFrames:pending.size, ...state()};
  } finally { stepping = false; }
};
Object.defineProperty(window, '__noodletAnimation', {value:Object.freeze({state, step})});
document.addEventListener('readystatechange', report);
document.addEventListener('visibilitychange', report);
report();
