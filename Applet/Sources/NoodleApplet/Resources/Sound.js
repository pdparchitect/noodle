(() => {
  // A recording hears what the page plays, even while the page is muted on the Mac.
  // Everything a page sends to an audio destination passes through a bus that a
  // recording can listen to; media elements join the recording's own context.
  const Context = window.AudioContext;
  if (!Context) return;
  const send = body => window.webkit.messageHandlers.noodle.postMessage(body);
  const connect = AudioNode.prototype.connect, disconnect = AudioNode.prototype.disconnect;
  const buses = new WeakMap(), contexts = [], routed = new WeakSet();
  const rate = 48000, frames = 4096;
  let capture = null, recorder = null;
  const busFor = context => {
    if (!(context instanceof Context)) return null;
    let bus = buses.get(context);
    if (!bus) {
      bus = context.createGain();
      connect.call(bus, context.destination);
      buses.set(context, bus);
      contexts.push(new WeakRef(context));
      recorder?.tap(context, bus);
    }
    return bus;
  };
  AudioNode.prototype.connect = function (target, ...rest) {
    const bus = target instanceof AudioDestinationNode && target.context !== capture ? busFor(target.context) : null;
    if (!bus) return connect.call(this, target, ...rest);
    connect.call(this, bus, ...rest);
    return target;
  };
  AudioNode.prototype.disconnect = function (target, ...rest) {
    const bus = target instanceof AudioDestinationNode ? buses.get(target.context) : null;
    return bus ? disconnect.call(this, bus, ...rest) : disconnect.call(this, ...arguments);
  };
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    recorder?.element(this);
    return play.apply(this, args);
  };
  document.addEventListener('play', event => recorder?.element(event.target), true);
  const encode = chunks => {
    const length = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
    const pcm = new Int16Array(length);
    let offset = 0;
    for (const chunk of chunks) { pcm.set(chunk, offset); offset += chunk.length; }
    const bytes = new Uint8Array(pcm.buffer);
    let binary = '';
    for (let i = 0; i < bytes.length; i += 32768) binary += String.fromCharCode(...bytes.subarray(i, i + 32768));
    return btoa(binary);
  };
  window.__noodletSound = {
    start() {
      if (recorder) return true;
      capture ??= new Context({sampleRate: rate});
      const mix = capture.createGain(), processor = capture.createScriptProcessor(frames, 2, 2);
      connect.call(mix, processor);
      connect.call(processor, capture.destination);
      const started = performance.now(), taps = [], inflight = new Set();
      let heard = null, sent = 0, queued = 0, chunks = [];
      const flush = () => {
        if (!queued) return;
        const message = send({operation: 'sound', pcm: encode(chunks), at: heard + sent / rate}).catch(() => {});
        sent += queued;
        queued = 0;
        chunks = [];
        inflight.add(message);
        message.finally(() => inflight.delete(message));
      };
      processor.onaudioprocess = event => {
        // The processor hands over a buffer once it has filled, so its first sample was heard a buffer ago.
        heard ??= Math.max(0, (performance.now() - started) / 1000 - frames / rate);
        const left = event.inputBuffer.getChannelData(0), right = event.inputBuffer.getChannelData(1);
        const pcm = new Int16Array(left.length * 2);
        for (let i = 0; i < left.length; i++) {
          pcm[2 * i] = Math.max(-1, Math.min(1, left[i])) * 32767;
          pcm[2 * i + 1] = Math.max(-1, Math.min(1, right[i])) * 32767;
        }
        chunks.push(pcm);
        queued += left.length;
        if (queued >= rate / 4) flush();
      };
      recorder = {
        tap(context, bus) {
          const stream = context.createMediaStreamDestination();
          connect.call(bus, stream);
          const source = capture.createMediaStreamSource(stream.stream);
          connect.call(source, mix);
          taps.push(() => { disconnect.call(bus, stream); disconnect.call(source); });
        },
        // Routing is permanent, so only media the page may read goes through the recording:
        // a cross-origin element would play silence from then on.
        element(element) {
          if (!(element instanceof HTMLMediaElement) || routed.has(element) || element.srcObject) return;
          const source = element.currentSrc || element.src;
          if (!/^(file|blob|data):/.test(source)) return;
          routed.add(element);
          try {
            const node = capture.createMediaElementSource(element);
            connect.call(node, capture.destination);
            connect.call(node, mix);
          } catch {
            // The page routed the element through its own context, whose bus is already heard.
          }
        },
        async stop() {
          processor.onaudioprocess = null;
          for (const untap of taps) untap();
          disconnect.call(mix);
          disconnect.call(processor);
          flush();
          await Promise.allSettled([...inflight]);
        },
      };
      for (const reference of contexts) {
        const context = reference.deref();
        if (context) recorder.tap(context, buses.get(context));
      }
      for (const element of document.querySelectorAll('audio,video')) recorder.element(element);
      capture.resume();
      return true;
    },
    async stop() {
      const current = recorder;
      recorder = null;
      await current?.stop();
      return true;
    },
  };
})();
