// Runs in the isolated control world. Coordinates are in the top-level CSS viewport.
const element = document.querySelector(target);
if (!element) throw Error('Element not found');
const ancestors = [];
for (let current = window; current !== current.top; current = current.parent) {
    let frame;
    try { frame = current.frameElement; } catch (_) {}
    if (!frame) throw Error('Cross-origin frame selectors cannot be positioned. Use main-viewport --x and --y from a screenshot.');
    ancestors.push(frame);
}
element.scrollIntoView({block: 'nearest', inline: 'nearest', behavior: 'instant'});
for (const frame of ancestors) frame.scrollIntoView({block: 'nearest', inline: 'nearest', behavior: 'instant'});
const rect = element.getBoundingClientRect();
if (!rect.width || !rect.height) throw Error('Element hidden or empty');
let x = (Math.max(0, rect.left) + Math.min(innerWidth, rect.right)) / 2;
let y = (Math.max(0, rect.top) + Math.min(innerHeight, rect.bottom)) / 2;
let top = document.elementFromPoint(x, y);
if (!(top === element || element.contains(top))) throw Error('Element hidden or covered');
for (const frame of ancestors) {
    const parent = frame.ownerDocument;
    for (let node = frame; node; node = node.parentElement) {
        if (parent.defaultView.getComputedStyle(node).transform !== 'none')
            throw Error('Transformed frame: use main-viewport --x and --y.');
    }
    const bounds = frame.getBoundingClientRect();
    x = bounds.left + (frame.clientLeft + x) * bounds.width / frame.offsetWidth;
    y = bounds.top + (frame.clientTop + y) * bounds.height / frame.offsetHeight;
    if (parent.elementFromPoint(x, y) !== frame) throw Error('Frame hidden or covered');
}
return {x, y};
