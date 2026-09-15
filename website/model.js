import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';

const story = document.querySelector('.story');
const stage = document.querySelector('.stage');
const copy = document.querySelector('.hero-copy');
const canvas = document.querySelector('.model-canvas');
const ground = document.querySelector('.ground');
const loading = document.querySelector('.model-loading');
const motion = matchMedia('(prefers-reduced-motion: reduce)');
const clamp = value => Math.max(0, Math.min(1, value));
const mix = (a, b, t) => a + (b - a) * t;
const rad = degrees => degrees * Math.PI / 180;
const smooth = (start, end, value) => {
  const t = clamp((value - start) / (end - start));
  return t * t * (3 - 2 * t);
};
let renderer, frame = 0, failed = false;
function fallback() {
  failed = true;
  cancelAnimationFrame(frame);
  story.classList.remove('is-animated');
  story.classList.add('is-static');
  copy.style.removeProperty('--copy-opacity');
  copy.style.removeProperty('--copy-y');
  loading.hidden = true;
  story.dataset.state = 'fallback';
  renderer?.dispose();
}

async function start() {
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false, powerPreference: 'low-power' });
  renderer.setClearColor(0x000000);
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = .8;
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(30, 1, 500, 4000);
  camera.position.z = 2000;
  const studio = new RoomEnvironment();
  const pmrem = new THREE.PMREMGenerator(renderer);
  const environment = pmrem.fromScene(studio, .04);
  scene.environment = environment.texture;
  scene.environmentIntensity = .35;
  studio.dispose();
  pmrem.dispose();
  const keyLight = new THREE.DirectionalLight(0xffffff, 1.5);
  keyLight.position.set(-500, 800, 1000);
  scene.add(keyLight);
  const rimLight = new THREE.DirectionalLight(0xdce5ff, 1);
  rimLight.position.set(600, 200, -600);
  scene.add(rimLight, new THREE.HemisphereLight(0xffffff, 0x242631, .5));

  const response = await fetch('./assets/macbook-m5.glb.gz');
  if (!response.ok) throw new Error('Model unavailable');
  const stream = response.body.pipeThrough(new DecompressionStream('gzip'));
  const [gltf, texture] = await Promise.all([
    new Response(stream).arrayBuffer().then(data => new GLTFLoader().parseAsync(data, './assets/')),
    new THREE.TextureLoader().loadAsync('./assets/workspace.png')
  ]);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.flipY = false;
  texture.anisotropy = Math.min(8, renderer.capabilities.getMaxAnisotropy());
  texture.repeat.y = (1490 / 1083) / (30.076 / 19.553);
  texture.offset.y = (1 - texture.repeat.y) / 2;
  const display = gltf.scene.getObjectByName('MacBookDisplay');
  const screen = new THREE.MeshBasicMaterial({ map: texture, color: 0xffffff, toneMapped: false, transparent: true, opacity: 0, depthWrite: false });
  display.material = screen;
  const model = gltf.scene.getObjectByName('MacBook');
  const lid = gltf.scene.getObjectByName('MacBookLid');
  const hinge = new THREE.Group();
  hinge.position.set(0, -10.772, 0);
  model.add(hinge);
  gltf.scene.updateMatrixWorld(true);
  hinge.attach(lid);

  // Source units are centimetres, with an open lid at 110 degrees.
  // Recenter the hinge and normalize the width to the CSS version's 800 units.
  const origin = new THREE.Group();
  origin.position.set(0, 0, .10772);
  origin.add(gltf.scene);
  const normalized = new THREE.Group();
  normalized.scale.setScalar(800 / .31174);
  normalized.add(origin);
  const rig = new THREE.Group();
  rig.add(normalized);
  scene.add(rig);
  const meshCorners = [];
  gltf.scene.traverse(object => {
    if (!object.isMesh) return;
    object.geometry.computeBoundingBox();
    const { min, max } = object.geometry.boundingBox;
    for (const x of [min.x, max.x]) for (const y of [min.y, max.y]) for (const z of [min.z, max.z]) {
      meshCorners.push({ object, point: new THREE.Vector3(x, y, z) });
    }
  });
  let width, height, travel, copyBottom;
  let current = 0, target = 0, previousTime = 0;
  function bounds(points, scale) {
    let left = Infinity, right = -Infinity, top = Infinity, bottom = -Infinity;
    for (const point of points) {
      const projection = scale * 2000 / (2000 - point.z * scale);
      left = Math.min(left, point.x * projection);
      right = Math.max(right, point.x * projection);
      top = Math.min(top, -point.y * projection);
      bottom = Math.max(bottom, -point.y * projection);
    }
    return { left, right, top, bottom, width: right - left, height: bottom - top };
  }
  function render(p) {
    const turn = smooth(0, .34, p), opening = smooth(.30, .86, p), settle = smooth(.36, .9, p);
    const cameraX = mix(mix(20, 80, turn), 72, settle);
    rig.scale.setScalar(1);
    rig.rotation.set(rad(90 - cameraX), rad(mix(22, 0, turn)), rad(mix(13, 0, turn)), 'XYZ');
    hinge.rotation.x = rad(110 - 104 * opening);
    rig.updateMatrixWorld(true);
    const points = meshCorners.map(({ object, point }) => point.clone().applyMatrix4(object.matrixWorld));
    const clearing = smooth(.12, .40, p);
    const top = motion.matches ? copyBottom + 24 : mix(copyBottom + 26, 87, clearing);
    const bottom = height - 34;
    let lo = .03, hi = 1.3;
    for (let i = 0; i < 18; i++) {
      const scale = (lo + hi) / 2, box = bounds(points, scale);
      if (box.width > width * (width < 735 ? .90 : .87) || box.height > Math.max(60, bottom - top)) hi = scale;
      else lo = scale;
    }
    const scale = Math.min(lo, mix(width < 735 ? .46 : .83, 1.3, smooth(.34, .80, p)));
    const box = bounds(points, scale);
    rig.scale.setScalar(scale);
    const x = -(box.left + box.right) / 2;
    const y = (top + bottom - box.top - box.bottom) / 2;
    camera.setViewOffset(width, height, -x, height / 2 - y, width, height);
    const reveal = smooth(.45, .87, p);
    screen.opacity = reveal;
    screen.color.setScalar(mix(.3, 1, reveal) ** 2.2);
    copy.style.setProperty('--copy-opacity', motion.matches ? 1 : 1 - smooth(.08, .31, p));
    copy.style.setProperty('--copy-y', (motion.matches ? 0 : -36 * clearing) + 'px');
    ground.style.setProperty('--shadow-width', box.width * .86 + 'px');
    ground.style.setProperty('--shadow-y', y + box.bottom + 6 + 'px');
    story.dataset.progress = p.toFixed(4);
    story.dataset.lidAngle = (104 * opening).toFixed(2);
    renderer.render(scene, camera);
  }
  function tick(time) {
    if (failed) return;
    const dt = previousTime ? Math.min(time - previousTime, 64) : 16;
    previousTime = time;
    current += (target - current) * (1 - Math.exp(-dt / 65));
    if (Math.abs(target - current) < .0001) current = target;
    render(current);
    if (current !== target && !document.hidden) frame = requestAnimationFrame(tick);
    else { frame = 0; previousTime = 0; }
  }
  function onScroll() {
    if (failed) return;
    target = motion.matches ? 1 : clamp(scrollY / travel);
    if (!frame && !document.hidden) frame = requestAnimationFrame(tick);
  }
  function measure() {
    if (failed) return;
    story.classList.toggle('is-animated', !motion.matches);
    width = stage.clientWidth;
    height = stage.clientHeight;
    travel = Math.max(1, story.offsetHeight - height);
    copyBottom = copy.offsetTop + copy.offsetHeight;
    renderer.setSize(width, height, false);
    camera.fov = 2 * Math.atan(height / 4000) * 180 / Math.PI;
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
    current = target = motion.matches ? 1 : clamp(scrollY / travel);
    render(current);
  }
  addEventListener('scroll', onScroll, { passive: true });
  addEventListener('resize', measure, { passive: true });
  addEventListener('pageshow', measure);
  document.addEventListener('visibilitychange', onScroll);
  motion.addEventListener('change', measure);
  canvas.addEventListener('webglcontextlost', fallback, { once: true });
  loading.hidden = true;
  story.dataset.state = 'ready';
  measure();
  if (parent !== window) parent.postMessage({ type: 'noodle-model-ready' }, location.origin);
}
start().catch(fallback);
