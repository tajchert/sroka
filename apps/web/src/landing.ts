// Landing hero: types through the "Read it …" endings once the save → phone animation has played.
const WORDS = ["later.", "offline.", "on the ✈️", "on your commute.", "in the waiting room.", "when you have time."];
const PLANE = /✈️?/;

const typed = document.querySelector<HTMLElement>("[data-typed]");
const emoji = document.querySelector<HTMLElement>("[data-typed-emoji]");
const caret = document.querySelector<HTMLElement>("[data-caret]");
const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

if (typed && emoji && caret && !reduced) {
  const render = (txt: string) => {
    typed.textContent = txt.replace(PLANE, "");
    emoji.textContent = txt.match(PLANE)?.[0] ?? "";
  };
  let w = 0;
  let txt = WORDS[0]!;
  let deleting = true;
  const tick = () => {
    if (deleting) {
      txt = Array.from(txt).slice(0, -1).join("");
      if (!txt) {
        deleting = false;
        w = (w + 1) % WORDS.length;
      }
      render(txt);
      setTimeout(tick, 45);
    } else {
      const word = WORDS[w]!;
      txt = Array.from(word).slice(0, Array.from(txt).length + 1).join("");
      render(txt);
      if (txt === word) {
        deleting = true;
        setTimeout(tick, 1900);
      } else setTimeout(tick, 85);
    }
  };
  setTimeout(() => caret.classList.add("on"), 5000);
  setTimeout(tick, 6200);
}

// Signed-in visitors get "Open library" CTAs. A localStorage hint flips them before the session probe answers.
const HINT = "sroka.signedIn";
const setSignedIn = (on: boolean) => {
  document.documentElement.classList.toggle("signed-in", on);
  try {
    if (on) localStorage.setItem(HINT, "1");
    else localStorage.removeItem(HINT);
  } catch {
    // storage blocked: the probe alone decides
  }
};
try {
  if (localStorage.getItem(HINT)) document.documentElement.classList.add("signed-in");
} catch {
  // storage blocked
}
fetch("/api/auth/get-session", { credentials: "same-origin" })
  .then((res) => (res.ok ? res.json() : null))
  .then((body: { user?: unknown } | null) => setSignedIn(Boolean(body?.user)))
  .catch(() => {
    // offline or API down: keep whatever the hint said
  });
