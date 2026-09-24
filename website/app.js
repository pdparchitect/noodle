// Noodle website — v5
// Keeps the nav quiet at the top of the page: the logo and Download button
// fade in only after the hero's own buttons have scrolled out of view.
(() => {
  const nav = document.querySelector(".nav");
  const heroCtas = document.querySelector(".intro .ctas");
  if (!nav || !heroCtas) return;
  if (!("IntersectionObserver" in window)) { nav.classList.add("show-cta"); return; }
  new IntersectionObserver(([entry]) => {
    const scrolledPast = !entry.isIntersecting && entry.boundingClientRect.top < 0;
    nav.classList.toggle("show-cta", scrolledPast);
  }, { rootMargin: "-48px 0px 0px 0px", threshold: 0 }).observe(heroCtas);
})();
