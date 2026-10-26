// Ch 3 seminar deck (2026-10-26), built with pptxgenjs in the style of the
// LOB sequencer talk (lob_sequencer/LimitOrderBook/slides/build_deck.js).
//
// Run:  NODE_PATH=<dir with node_modules/pptxgenjs> node docs/build_deck.js
// Figures: figures/deck_lay (plain-language axes) for the main slides,
// figures/deck (technical) for backup, figures/deck/mock_odd_overview.png for
// the model slide, and the chapter's fig1 (vault bank) from the dissertation repo.
// Content and numbers: docs/deck_2026-10-26.md.

const pptxgen = require("pptxgenjs");
const fs = require("fs");
const path = require("path");
const { applyTheme } = require("/home/simaliang/.claude/skills/synced/d07e7264-f0d5-4623-9ed4-ad7177ade828_02559757-4580-4433-bf48-512af72d4783/pptx/scripts/apply_theme.js");

const REPO = path.resolve(__dirname, "..");
const OUT = path.join(REPO, "docs", "deck_2026-10-26_seminar.pptx");
const DIMS = process.env.DIMS ? JSON.parse(fs.readFileSync(process.env.DIMS, "utf8")) : {};
const FIG = {
  odd: path.join(REPO, "figures/deck/mock_odd_overview.png"),
  ladder: path.join(REPO, "figures/deck/ladder.png"),
  e01: path.join(REPO, "figures/deck_lay/e01_sorting.png"),
  e05: path.join(REPO, "figures/deck_lay/e05_pfail_by_mu.png"),
  e07: path.join(REPO, "figures/deck_lay/e07_herding.png"),
  e08: path.join(REPO, "figures/deck_lay/e08_pfail_by_signal.png"),
  e10: path.join(REPO, "figures/deck_lay/e10_concentration.png"),
  e03: path.join(REPO, "figures/deck/e03_tests_by_bank.png"),
  e04: path.join(REPO, "figures/deck/e04_oneshot_by_size.png"),
  e06: path.join(REPO, "figures/deck/e06_withdraw_by_mu.png"),
  e09: path.join(REPO, "figures/deck/e09_channels.png"),
  fig1: "/home/simaliang/Papers/bank_run_dissertation/chapters/abm/figures/fig1_p6a_headline.png",
};
// width / height of each figure (fallbacks if DIMS is not supplied)
const AR = {
  odd: 0.985, ladder: 2.857, e01: 1.563, e05: 1.501, e07: 1.569, e08: 2.104, e10: 1.501,
  e03: 2.181, e04: 1.590, e06: 2.400, e09: 1.788, fig1: 1.521,
};
function ar(key) {
  const p = FIG[key];
  for (const k of Object.keys(DIMS)) if (p.endsWith(k) || k.endsWith(path.basename(p))) return DIMS[k];
  return AR[key];
}

const THEME = {
  name: "Bank Run Talk",
  headFontFace: "Cambria",
  bodyFontFace: "Calibri",
  colors: {
    dk1: "1F2937", lt1: "FFFFFF", dk2: "16213E", lt2: "EEF2F9",
    accent1: "3B6BB5", accent2: "C9502E", accent3: "6B7280",
    accent4: "D9E3F3", accent5: "2E7D5B", accent6: "E08A2E",
    hlink: "3B6BB5", folHlink: "6B7280",
  },
};
// the figures' own colours, so type labels on slides match the plots
const IND = "EB6834"; // individualists, orange
const COL = "2A78D6"; // collectivists, blue

const pres = new pptxgen();
pres.layout = "LAYOUT_16x9"; // 10 x 5.625
pres.theme = { headFontFace: THEME.headFontFace, bodyFontFace: THEME.bodyFontFace };
pres.author = "Walter Stover";
pres.title = "A bank run model for the twentieth century";
const C = pres.SchemeColor;
const FOOT = "A bank run model for the twentieth century";

// ---------- layouts ----------
pres.defineSlideMaster({
  title: "DARK",
  background: { color: THEME.colors.dk2 },
  objects: [
    { placeholder: { options: { name: "title", type: "title", x: 0.6, y: 1.6, w: 8.8, h: 1.6, fontSize: 34, bold: true, color: C.background1, valign: "bottom", align: "left", margin: 0 } } },
    { placeholder: { options: { name: "body", type: "body", x: 0.6, y: 3.3, w: 8.8, h: 1.2, fontSize: 18, color: C.accent4, valign: "top", margin: 0 } } },
  ],
});
pres.defineSlideMaster({
  title: "CONTENT",
  background: { color: THEME.colors.lt1 },
  objects: [
    { placeholder: { options: { name: "title", type: "title", x: 0.5, y: 0.3, w: 9.0, h: 0.75, fontSize: 24, bold: true, color: C.text2, valign: "middle", align: "left", margin: 0 } } },
    { text: { text: FOOT, options: { x: 0.5, y: 5.2, w: 6, h: 0.3, fontSize: 9, color: C.accent3, margin: 0 } } },
  ],
  slideNumber: { x: 9.1, y: 5.2, w: 0.5, h: 0.3, fontSize: 9, color: THEME.colors.accent3, align: "right" },
});
pres.defineSlideMaster({
  title: "SECTION",
  background: { color: THEME.colors.dk2 },
  objects: [
    { placeholder: { options: { name: "title", type: "title", x: 0.6, y: 2.0, w: 8.8, h: 1.2, fontSize: 32, bold: true, color: C.background1, valign: "middle", align: "left", margin: 0 } } },
    { placeholder: { options: { name: "body", type: "body", x: 0.6, y: 3.25, w: 8.8, h: 0.8, fontSize: 16, color: C.accent4, valign: "top", margin: 0 } } },
  ],
});

// ---------- helpers ----------
function fig(slide, key, x, y, maxW, maxH, opts = {}) {
  const a = ar(key);
  let w = maxW, h = maxW / a;
  if (h > maxH) { h = maxH; w = maxH * a; }
  const dx = opts.align === "center" ? (maxW - w) / 2 : opts.align === "right" ? maxW - w : 0;
  slide.addImage({ path: FIG[key], x: x + dx, y, w, h, objectName: key, altText: opts.alt || key });
  return { w, h, x: x + dx };
}
function card(slide, x, y, w, h, opts = {}) {
  slide.addShape(pres.ShapeType.roundRect, {
    x, y, w, h, rectRadius: 0.08,
    fill: { color: opts.fill || C.background2 },
    line: opts.line ? { color: opts.line, width: 0.75 } : { color: opts.fill || C.background2, width: 0 },
    objectName: opts.name || "card",
  });
}
function stat(slide, x, y, w, big, label, opts = {}) {
  const color = opts.color || C.accent1;
  const h = opts.h || 1.1;
  const bigH = opts.bigH || 0.5;
  card(slide, x, y, w, h, { fill: opts.fill || C.background2, name: "stat-" + label.slice(0, 20) });
  slide.addText(big, { x: x + 0.15, y: y + 0.08, w: w - 0.3, h: bigH, fontSize: opts.size || 26, bold: true, color, fontFace: "Cambria", margin: 0, isTextBox: true, valign: "middle", objectName: "stat-big" });
  slide.addText(label, { x: x + 0.15, y: y + bigH + 0.1, w: w - 0.3, h: h - bigH - 0.16, fontSize: opts.labelSize || 11, color: C.accent3, margin: 0, isTextBox: true, valign: "top", objectName: "stat-label" });
}
function bullets(slide, items, x, y, w, h, opts = {}) {
  const arr = items.map((t, i) => {
    const o = { bullet: { indent: 14 }, breakLine: i < items.length - 1, paraSpaceAfter: opts.gap ?? 6 };
    if (typeof t === "string") return { text: t, options: o };
    return { text: t.text, options: Object.assign(o, t.options || {}) };
  });
  slide.addText(arr, { x, y, w, h, fontSize: opts.size || 14, color: C.text1, valign: opts.valign || "top", margin: 0, isTextBox: true, objectName: opts.name || "bullets" });
}
function caption(slide, text, x, y, w) {
  slide.addText(text, { x, y, w, h: 0.3, fontSize: 10, italic: true, color: C.accent3, margin: 0, isTextBox: true, objectName: "caption" });
}
// a card with a bold head and a body paragraph
function textCard(slide, x, y, w, h, head, body, opts = {}) {
  card(slide, x, y, w, h, { fill: opts.fill || C.background2, name: "card-" + head.slice(0, 20) });
  slide.addText(head, { x: x + 0.15, y: y + 0.1, w: w - 0.3, h: 0.32, fontSize: opts.headSize || 13, bold: true, color: opts.headColor || C.accent1, margin: 0, isTextBox: true, objectName: "card-head" });
  slide.addText(body, { x: x + 0.15, y: y + 0.45, w: w - 0.3, h: h - 0.55, fontSize: opts.bodySize || 11.5, color: C.text1, margin: 0, isTextBox: true, valign: "top", objectName: "card-body" });
}
// the deck's motif: a small rounded chip, used for lambda pairs and numbered rows
function chip(slide, label, x, y, w, h, opts = {}) {
  slide.addShape(pres.ShapeType.roundRect, { x, y, w, h, rectRadius: 0.06, fill: { color: opts.fill || C.accent1 }, line: { color: opts.fill || C.accent1, width: 0 }, objectName: "chip" });
  slide.addText(String(label), { x, y, w, h, fontSize: opts.fontSize || 12, bold: true, color: opts.color || C.background1, align: "center", valign: "middle", margin: 0, isTextBox: true, fontFace: "Cambria", objectName: "chip-label" });
}

(async () => {
  let s, d;

  // ================= 1. Title =================
  pres.addSection({ title: "Opening" });
  s = pres.addSlide({ masterName: "DARK", sectionTitle: "Opening" });
  s.addText("A bank run model for the twentieth century", { placeholder: "title" });
  s.addText([
    { text: "Who runs, and how a run spreads: an agent-based test of the theory", options: { breakLine: true } },
    { text: "Walter Stover  ·  George Mason University  ·  26 October 2026", options: { fontSize: 14, color: C.accent3 } },
  ], { placeholder: "body" });
  s.addNotes("Working title is the chapter title; change for the seminar if you like. ~0.5 min.");

  // ================= 2. The puzzle =================
  s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Opening" });
  s.addText("The puzzle: who runs, and how a run spreads", { placeholder: "title" });
  const ctx = [
    ["Diamond–Dybvig", "A run is an equilibrium. The theory says runs can happen; it says nothing about who runs first or how a run spreads."],
    ["Chapter 1: theory", "Depositors differ in how much they weigh their own information against public news and what others do. That difference predicts who moves first, and in which direction, given the news."],
    ["Chapter 2: Celsius", "Those differences show up in real withdrawals. But one platform and one shock cannot vary the mix of depositors or the information they received."],
  ];
  ctx.forEach(([h, b], i) => textCard(s, 0.5 + i * 3.05, 1.15, 2.9, 1.6, h, b, { headColor: C.text2 }));
  card(s, 0.5, 2.9, 9.0, 0.95, { fill: C.accent4, name: "ch3" });
  s.addText([
    { text: "Chapter 3, this talk: ", options: { bold: true, color: C.accent1 } },
    { text: "a population of interacting depositors in which the mix of types, the public signal, deposit concentration and the bank’s contract can each be varied. Does the theory’s mechanism survive there?" },
  ], { x: 0.65, y: 2.95, w: 8.7, h: 0.85, fontSize: 12.5, color: C.text1, margin: 0, isTextBox: true, valign: "middle", objectName: "ch3-text" });
  const defs = [
    ["D", "share of individualists who withdraw minus share of collectivists, among depositors the shock did not hit"],
    ["P(fail)", "share of runs that end with the bank failing"],
  ];
  defs.forEach(([big, lab], i) => {
    const x = 0.5 + i * 4.6;
    card(s, x, 4.0, 4.4, 1.0, { name: "def-" + big });
    s.addText(big, { x: x + 0.15, y: 4.05, w: 1.3, h: 0.9, fontSize: 24, bold: true, color: C.accent1, fontFace: "Cambria", margin: 0, isTextBox: true, valign: "middle", objectName: "def-big" });
    s.addText(lab, { x: x + 1.5, y: 4.05, w: 2.8, h: 0.9, fontSize: 11, color: C.accent3, margin: 0, isTextBox: true, valign: "middle", objectName: "def-label" });
  });
  s.addNotes("~1.5 min. Theory (Diamond–Dybvig) says runs can happen; it is silent on who runs first and how a run spreads. Optional visual: a historical photo of a bank run.");

  // ---- bare-bones argument slides (to be condensed later) ----
  function stepSlide(n, title, lead, items, notes, opts = {}) {
    const sl = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Opening" });
    sl.addText(title, { placeholder: "title" });
    chip(sl, n, 0.5, 1.25, 0.42, 0.42, { fontSize: 13 });
    sl.addText(lead, { x: 1.1, y: 1.15, w: 8.4, h: 0.95, fontSize: 17, bold: true, color: C.text2, margin: 0, isTextBox: true, valign: "middle", objectName: "step-lead" });
    const runs = [];
    items.forEach(([h, b], i) => {
      const last = i === items.length - 1;
      runs.push({ text: h + " ", options: { bold: true, bullet: { indent: 14 }, paraSpaceAfter: 9, breakLine: false } });
      runs.push({ text: b, options: { breakLine: !last, paraSpaceAfter: 9 } });
    });
    sl.addText(runs, { x: 1.1, y: 2.3, w: 8.4, h: 2.3, fontSize: 14, color: C.text1, valign: "top", margin: 0, isTextBox: true, objectName: "step-items" });
    if (opts.foot) sl.addText(opts.foot, { x: 1.1, y: 4.65, w: 8.4, h: 0.35, fontSize: 11, italic: true, color: C.accent3, margin: 0, isTextBox: true, objectName: "step-foot" });
    sl.addNotes(notes);
    return sl;
  }

  stepSlide(1, "Two mechanisms the literature has used",
    "Who runs, and when, has been answered two ways: by luck and by position.",
    [
      ["Dispersion.", "Goldstein–Pauzner give every depositor a noisy draw of the same signal. The draw breaks common knowledge and selects the equilibrium. Who runs first is whoever drew low."],
      ["Delivery.", "Networks and media decide who hears what, from whom, when (Kelly–Ó Gráda, Iyer–Puri, Cookson et al.). Who runs first is whoever sits nearest the source."],
      ["Both are fruitful.", "Neither says anything about the depositor: the same Bayesian, with the same prior, sits at every node."],
    ],
    "~1 min. The two mechanisms the literature has used to answer who runs and when. Dispersion: Goldstein-Pauzner's noisy private signal, the device that gives Diamond-Dybvig an equilibrium-selection mechanism; depositors are ex ante identical, so the order is luck. Delivery: the network and media literature; the order is position. Both are consistent with identical processing.");

  stepSlide(2, "With two signals, a third question appears",
    "Which signal does a depositor act on, and in what proportion?",
    [
      ["Latent in the canonical models.", "Diamond–Dybvig has no signal; Morris–Shin and Goldstein–Pauzner have one. The question cannot arise."],
      ["Askable once a public signal is added.", "Morris–Shin (2002), Hellwig (2002), Angeletos–Werning (2006) put a public signal next to the private one."],
      ["The question a panic poses.", "A depositor in a run holds two things that disagree: what they see and what they are told."],
    ],
    "~1 min. The third question is latent in the canonical theory because those models have one signal. It becomes askable once a public signal is added, which the global-games literature did in the early 2000s. It is exactly the question a panic poses.");

  stepSlide(3, "How the theory answers it: the Bayesian precision ratio",
    "Weight on the public signal = its precision relative to the private one. The same for everyone, and vanishing.",
    [
      ["The same for everyone.", "Two depositors with the same signals form the same belief. There is no ‘who’."],
      ["Vanishing.", "As private information sharpens, the weight on the public line goes to zero. The public signal matters only while depositors know little."],
      ["What it predicts about a panic.", "Any sorting between depositors is noise, and official communication stops mattering just when depositors are paying most attention."],
    ],
    "~1 min. The public-signal papers answer the question with the Bayesian precision ratio: the weight on y is tau_y over tau_x plus tau_y. Two consequences: the weight is uniform across depositors, so there is no who; and it vanishes as the private signal gets precise. Both are at odds with what panics look like.");

  stepSlide(4, "Panics do not look like that",
    "Panics are open disagreements between the public line and private evidence, and depositors split on which to trust.",
    [
      ["Celsius, 2022.", "Official posts insisting the platform was sound, while CEL fell and withdrawals accelerated."],
      ["Silicon Valley Bank, 2023.", "A call asking clients to stay calm, against a Twitter feed saying the opposite."],
      ["Northern Rock, 2007.", "A Bank of England support announcement, against queues outside the branches."],
    ],
    "~1 min. Counterexamples. In each case the public line and private evidence are in open disagreement, the weights do not vanish, and the interesting fact is who moved on which. Chapter 3's stale public signal is the general case.",
    { foot: "In each case the interesting fact is who moved on which signal." });

  stepSlide(5, "Cultural economics: a source of stable weights",
    "Culture supplies a weight that differs across depositors, is set before the run, and does not move with the information environment.",
    [
      ["Transmitted, not chosen.", "Cultural values pass largely unchanged from parents to children (Guiso, Sapienza, Zingales; Bazzi et al.). The weight is a disposition, not a calculation."],
      ["Individualism is the right dimension.", "Self-reliance against deference to the group (Hofstede) is the private-against-social weighting the model already contains (Gorodnichenko–Roland)."],
      ["Measurable per depositor.", "Given names carry it (Twenge et al.), so the weight can be observed, not assumed."],
    ],
    "~1 min. Cultural economics gives a source of the weight that satisfies the three things the model needs: heterogeneity, positivity, and stability with respect to the information environment. Individualism is the dimension that maps onto the private-versus-social weighting, and names make it measurable at the individual level.");

  stepSlide(6, "What this dissertation does with it",
    "The weight is the depositor’s psychological characteristic; culture is the population-level source.",
    [
      ["Chapter 1 formalises it.", "A stale public signal and heterogeneous dispositional weights inside Goldstein–Pauzner. Prediction: who runs first reverses with the sign of the public error."],
      ["Chapter 2 observes it once.", "Celsius: individualism predicts direction and timing within platform and within ancestral origin, and which public signals depositors act on."],
      ["Chapter 3 varies it.", "The mix of types, the gap between them, the staleness of the news, and the bank’s contract, in a population of interacting depositors."],
    ],
    "~1 min. Where the three chapters sit on the through-line. Then the ladder as the recap, then the model.");

  stepSlide(7, "Why the third chapter is a simulation",
    "Chapter 1 relaxed one assumption. The agent-based model relaxes the rest at once, and lets the three rungs interact.",
    [
      ["Chapter 1 relaxed one thing.", "The precision ratio became a stable, heterogeneous weight on a stale public signal. Everything else stayed: a continuum of depositors, one simultaneous move, no network."],
      ["The model relaxes the rest at once.", "Dispersion (a private draw per depositor), delivery (a network, neighbours’ withdrawals arriving tick by tick, public news absent, accurate or stale), interpretation (λ, formed in a cultural warm-up), plus deposit sizes, risk preferences and the contract."],
      ["An analytical model cannot carry all of that.", "Each addition breaks the threshold-equilibrium machinery; together they are beyond closed form. The simulation is what lets the rungs be varied and measured separately."],
    ],
    "~1 min. Why Chapter 3 is a simulation. Chapter 1 relaxed the Bayesian precision answer and kept the rest of Goldstein-Pauzner so the threshold equilibrium survives. The ABM relaxes dispersion, delivery and interpretation together, plus the incentive side, which no closed-form model could carry; that is what lets the channel decomposition (lambda on the neighbour blend vs the news blend) be measured at all.");

  // ================= 2b. The ladder =================
  s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Opening" });
  s.addText("The ladder: dispersed, delivered, interpreted", { placeholder: "title" });
  d = fig(s, "ladder", 0.5, 1.2, 9.0, 3.0, { align: "center", alt: "Three panels. Dispersed: one bank fundamental sends a noisy private signal to each depositor, who line up from run to stay. Delivered: a network in which the signal has reached some depositors from a first hearer and not others. Interpreted: the same private and public signals reach an individualist, who leans on the private signal, and a collectivist, who leans on the public one; culture sets the weight." });
  card(s, 0.5, 1.2 + d.h + 0.15, 9.0, 0.62, { fill: C.accent4, name: "ladder-note" });
  s.addText([
    { text: "Rungs 1 and 2 are the literature. ", options: { color: C.accent3 } },
    { text: "Rung 3 is this dissertation: ", options: { bold: true, color: C.accent1 } },
    { text: "the only one that orders depositors by a trait, and reverses when the public line is too optimistic or too pessimistic." },
  ], { x: 0.65, y: 1.2 + d.h + 0.18, w: 8.7, h: 0.56, fontSize: 12, color: C.text1, margin: 0, isTextBox: true, valign: "middle", objectName: "ladder-text" });
  s.addNotes("~1 min. The ladder: dispersion of the signal (Goldstein-Pauzner: same signal technology, different draws, which selects the equilibrium), heterogeneity in delivery (who hears it, from whom, when: Kelly-O Grada, Iyer-Puri, Cookson et al.), heterogeneity in interpretation (the same two signals, different dispositional weights; culture is the stable source). Rung 1 orders depositors by luck, rung 2 by position, rung 3 by who they are, and only rung 3 predicts that the order flips with the sign of the public error. Nearest cousins to acknowledge if asked: Izmalkov-Yildiz 2010 (heterogeneous priors), He-Manela 2016 (information acquisition).");

  // ================= 3. The model =================
  pres.addSection({ title: "The model" });
  s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "The model" });
  s.addText("The model in one picture", { placeholder: "title" });
  d = fig(s, "odd", 0.5, 1.15, 3.9, 3.85, { alt: "Model overview: depositors on a social network with a bank; each run draws fundamentals and signals, a shock hits, then depositors observe neighbours and news, form beliefs, and decide whether to withdraw, tick by tick." });
  const sx = 0.5 + d.w + 0.35, sw = (9.5 - sx - 0.15) / 2;
  stat(s, sx, 1.15, sw, "1,000", "depositors on a small-world network, one bank", { h: 1.05 });
  stat(s, sx + sw + 0.15, 1.15, sw, "1%", "cap on any one deposit; sizes log-normal (σ 2.5) below it", { h: 1.05 });
  stat(s, sx, 2.35, sw, "CARA 0.1", "risk aversion; partial withdrawals allowed", { h: 1.05, size: 22 });
  stat(s, sx + sw + 0.15, 2.35, sw, "250", "runs per cell: 25 initialisations × 10 draws", { h: 1.05 });
  bullets(s, [
    "One bank that sells its long asset at a discount when cash runs short (a fire-sale bank)",
    "Each tick a depositor sees neighbours’ withdrawals and the public news, blends them with a private signal, and withdraws if that pays",
    "A public signal can be absent, accurate, or outdated",
  ], sx, 3.6, 9.5 - sx, 1.45, { size: 12, gap: 5 });
  s.addNotes("~2 min. N = 1,000 depositors on a small-world network; one bank that sells assets at a discount when cash runs short (fire-sale bank). Each tick a depositor sees neighbours' withdrawals and the public news, blends them with a private signal, and withdraws if that pays. Reference bank: deposits log-normal (sigma 2.5), each capped at 1% of the total; CARA 0.1; partial withdrawals allowed. The diagram is the technical ODD overview: walk the right-hand column (warm-up, world, shock, tick loop) and skip the formulas.");

  // ================= 4. Who listens to whom =================
  s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "The model" });
  s.addText("Individualists and collectivists: who listens to whom", { placeholder: "title" });
  const types = [
    ["Individualists", IND, ["Trust their own information about the bank", "Put little weight on what neighbours do or on public news", "Weight on the social side: λ = 0.1 to 0.3", "Act on what they see themselves"]],
    ["Collectivists", COL, ["Watch what neighbours do and what the public news says", "Put little weight on their own information", "Weight on the social side: λ = 0.5 to 0.9", "Move when others move"]],
  ];
  types.forEach(([h, col, items], i) => {
    const x = 0.5 + i * 4.6;
    card(s, x, 1.15, 4.4, 2.6, { name: "type-" + h });
    s.addText(h, { x: x + 0.2, y: 1.25, w: 4.0, h: 0.4, fontSize: 18, bold: true, color: col, margin: 0, isTextBox: true, objectName: "type-head" });
    bullets(s, items, x + 0.2, 1.75, 4.0, 1.9, { size: 13, gap: 5 });
  });
  s.addText("Three pairs (λ individualist, λ collectivist) in the figures", { x: 0.5, y: 3.95, w: 5, h: 0.3, fontSize: 11, bold: true, color: C.accent3, margin: 0, isTextBox: true, objectName: "pairs-head" });
  const pairs = [["(0.1, 0.9)", "wide gap"], ["(0.2, 0.8)", "medium"], ["(0.3, 0.5)", "narrow"]];
  pairs.forEach(([p, lab], i) => {
    const x = 0.5 + i * 1.75;
    chip(s, p, x, 4.3, 1.0, 0.36, { fill: i === 0 ? C.text2 : i === 1 ? C.accent3 : C.accent4, color: i === 2 ? C.text1 : C.background1, fontSize: 11 });
    s.addText(lab, { x: x + 1.05, y: 4.3, w: 0.7, h: 0.36, fontSize: 11, color: C.accent3, margin: 0, isTextBox: true, valign: "middle", objectName: "pair-label" });
  });
  s.addText([
    { text: "The share of individualists μ is set by a cultural warm-up on the network. ", options: {} },
    { text: "Orange = individualists", options: { color: IND, bold: true } },
    { text: ", ", options: {} },
    { text: "blue = collectivists", options: { color: COL, bold: true } },
    { text: " throughout.", options: {} },
  ], { x: 5.8, y: 3.95, w: 3.7, h: 0.9, fontSize: 11, color: C.accent3, margin: 0, isTextBox: true, valign: "top", objectName: "mu-note" });
  s.addNotes("~1 min. Individualists put little weight on others (neighbours and public news) and more on their own information; collectivists the reverse. In the model: weight on the social side lambda; pairs shown in the figures (I, C): (0.1, 0.9) = large difference, (0.2, 0.8) = medium, (0.3, 0.5) = small. Type comes from a cultural warm-up on the network: the top mu share become individualists. Colours used throughout: orange = individualists, blue = collectivists.");

  // ---- figure + stats layout shared by the four result slides ----
  const FX = 0.5, FY = 1.15, FW = 6.0, FH = 3.6, SX = 6.8, SW = 2.7;

  // ================= 5. Herding =================
  pres.addSection({ title: "Results" });
  s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Results" });
  s.addText("Collectivists herd", { placeholder: "title" });
  d = fig(s, "e07", FX, FY, FW, FH, { alt: "Chance of withdrawing by share of neighbours who have withdrawn: collectivists jump to near 1 once 20 to 35 percent of neighbours are out; individualists level off near 0.25 to 0.30." });
  caption(s, "Chance of withdrawing, given the share of a depositor’s neighbours who have already withdrawn. λ pairs pooled; reference bank.", FX, FY + d.h + 0.05, FW);
  stat(s, SX, 1.15, SW, "0.15 to 0.93", "collectivists, once 20–35% of their neighbours are out", { color: COL, size: 22 });
  stat(s, SX, 2.4, SW, "0.25 to 0.30", "where individualists level off, whatever their neighbours do", { color: IND, size: 22 });
  stat(s, SX, 3.65, SW, "+0.58", "difference in slopes (collectivists 0.80, individualists 0.22), t = 16.7", { h: 1.2 });
  s.addNotes("~2 min. Collectivists jump from 0.15 to 0.93 once 20–35% of neighbours are out and reach 1.0; individualists plateau at ~0.25–0.30. Slopes: C 0.80, I 0.22 (difference +0.58, t 16.7). Lambda pairs pooled; reference bank.");

  // ================= 6. P(fail) by mu =================
  s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Results" });
  s.addText("More individualists, fewer failures", { placeholder: "title" });
  d = fig(s, "e05", FX, FY, FW, FH, { alt: "Chance the bank fails by share of individualists: falls from about 0.67 with no individualists to about 0.08 with all individualists for the large difference pair; monotone for every pair." });
  caption(s, "Chance the bank fails, by share of individualists μ, one line per λ pair. Includes the pure populations (μ 0 and 1).", FX, FY + d.h + 0.05, FW);
  stat(s, SX, 1.15, SW, "0.67 to 0.08", "P(fail) from no individualists to all, wide λ gap", { size: 22 });
  stat(s, SX, 2.4, SW, "0.25 to 0.09", "the same, narrow λ gap: it matters most when collectivists dominate", { size: 22 });
  textCard(s, SX, 3.65, SW, 1.2, "Monotone", "No interior peak at any mix. The lines converge once individualists are 75% or more.", { headColor: C.text2 });
  s.addNotes("~2 min. Large difference (0.1, 0.9): 0.67 at mu 0 -> 0.08 at mu 1; medium (0.2, 0.8) similar; small (0.3, 0.5): 0.25 -> 0.09. Monotone, no interior peak. The difference between types matters most when collectivists dominate; lines converge at mu >= 0.75. Includes pure cells (mu 0 and 1). If asked about Ch 1's non-monotonic prediction (P6): see backup.");

  // ================= 7. Public signal =================
  s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Results" });
  s.addText("Outdated news cuts both ways", { placeholder: "title" });
  d = fig(s, "e08", FX, FY, FW, FH, { alt: "Chance the bank fails by kind of public news: outdated pessimistic news raises it to about 0.48, accurate news barely changes it from no news (0.29 vs 0.31), outdated optimistic news lowers it to 0.16." });
  caption(s, "Chance the bank fails, by the kind of public news, dot and CI per λ pair. All mixes μ. Numbers at right: wide λ gap.", FX, FY + d.h + 0.05, FW);
  const sig = [["0.48", "outdated, pessimistic news"], ["0.31", "no public news"], ["0.29", "accurate news"], ["0.16", "outdated, optimistic news"]];
  sig.forEach(([b, l], i) => stat(s, SX, 1.15 + i * 0.97, SW, b, l, { h: 0.85, bigH: 0.4, size: 22, color: i === 0 ? C.accent2 : i === 3 ? C.accent5 : C.accent1 }));
  s.addNotes("~2.5 min. Large difference (0.1, 0.9): outdated pessimistic 0.48, none 0.31, accurate 0.29, outdated middling (y0 0.5) 0.18, outdated optimistic 0.16. Accurate news barely changes failure; stale optimistic halves it; stale pessimistic raises it by half. Small difference (0.3, 0.5) barely moves (0.09–0.15). All mu. Policy framing: the information environment (right to reassure), not sorting depositors by type.");

  // ================= 8. Concentration =================
  s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Results" });
  s.addText("Capping the largest deposits", { placeholder: "title" });
  d = fig(s, "e10", FX, FY, FW, FH, { alt: "Chance the bank fails by share of individualists for three deposit-size distributions: uncapped large deposits fail most often; capped at 1 percent matches the bank with similar-sized deposits at every share." });
  caption(s, "Chance the bank fails by share of individualists, for three deposit-size distributions. λ pairs pooled.", FX, FY + d.h + 0.05, FW);
  stat(s, SX, 1.15, SW, "0.61 to 0.11", "uncapped: a few very large deposits (σ 2.5)", { size: 22, color: C.accent2 });
  stat(s, SX, 2.4, SW, "0.51 to 0.08", "capped: no deposit above 1% of the total (the reference bank)", { size: 22 });
  stat(s, SX, 3.65, SW, "0.50 to 0.08", "similar sizes (σ 1). The μ gradient is the same in all three.", { size: 22, h: 1.2, color: C.accent3 });
  s.addNotes("~2 min. Lambda pairs pooled. Uncapped (sigma 2.5) 0.61 -> 0.11; capped at 1% 0.51 -> 0.08; similar sizes (sigma 1) 0.50 -> 0.08. Capping brings failure down to the no-concentration level at every mu. The mu gradient is the same in all three: culture's effect does not depend on concentration. One spoken sentence on what 'capped at 1%' means (no single depositor holds more than 1% of the bank).");

  // ================= 9. Validation =================
  pres.addSection({ title: "Validation" });
  s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Validation" });
  s.addText("Does the model hold up?", { placeholder: "title" });
  d = fig(s, "e01", FX, FY, FW, FH, { alt: "Individualists' run rate minus collectivists', relative to no news, against how far public news is from the truth: rises from negative when news is pessimistic to positive when optimistic, more steeply for the wide lambda gap." });
  caption(s, "D relative to no news, against how far the public news sits from the truth. Shaded: where Chapter 1 predicts the sign.", FX, FY + d.h + 0.05, FW);
  card(s, SX, 1.15, SW, 2.3, { name: "tests" });
  s.addText([
    { text: "Pre-registered tests", options: { bold: true, fontSize: 13, color: C.text2, breakLine: true, paraSpaceAfter: 6 } },
    { text: "G1′  optimistic news: individualists run more   +0.033", options: { fontSize: 10.5, breakLine: true, paraSpaceAfter: 3 } },
    { text: "G4′  pessimistic news: collectivists run more   −0.031", options: { fontSize: 10.5, breakLine: true, paraSpaceAfter: 3 } },
    { text: "G2a′  the effect grows with the λ gap   +0.093", options: { fontSize: 10.5, breakLine: true, paraSpaceAfter: 3 } },
    { text: "G3  sorting with no news: counts against (one pair wrong-signed)", options: { fontSize: 10.5, color: C.accent2 } },
  ], { x: SX + 0.15, y: 1.25, w: SW - 0.3, h: 2.1, fontSize: 10.5, color: C.text1, margin: 0, isTextBox: true, valign: "top", objectName: "tests-text" });
  stat(s, SX, 3.6, SW, "3 of 4", "confirmatory tests support the theory, on all three versions of the bank", { h: 1.25 });
  s.addNotes("~1.5 min. Ch 1's theory predicts: optimistic news -> individualists run more than collectivists; pessimistic -> collectivists run more. The lines rise through zero as predicted. Large difference reaches about ±0.1; small stays flat. Pre-registered tests: 3 of 4 support, on all three versions of the bank (r1k pooled: G1' +0.033, G4' -0.031, G2a' +0.093, Holm-significant; G3 counts against). Option: make this one sentence and move the figure to backup.");

  // ================= 10. Takeaways =================
  pres.addSection({ title: "Close" });
  s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Close" });
  s.addText("Takeaways and next steps", { placeholder: "title" });
  const take = [
    ["Sorting follows the news", "Optimistic public news makes individualists run relatively more; pessimistic news, collectivists. 3 of 4 pre-registered tests pass, in all three bank versions."],
    ["Collectivists herd", "Their chance of withdrawing jumps from 0.15 to 0.93 once 20–35% of neighbours are out; individualists level off near 0.3."],
    ["More individualists, fewer failures", "P(fail) falls from 0.67 to 0.08 as the individualist share goes from 0 to 1. Monotone; no interior peak."],
    ["Stale news cuts both ways", "A stale optimistic signal halves failure, a stale pessimistic one raises it by half. Accurate news barely moves it."],
    ["Capping the largest deposits", "A 1% cap brings failure down to the no-concentration bank’s level; the culture gradient is unchanged."],
    ["Not yet matched", "How Celsius’s largest depositors exit: one-shot share 0.35 there, 0.93 or more in the model."],
  ];
  take.forEach(([h, b], i) => {
    const y = 1.15 + i * 0.64, rh = 0.56;
    card(s, 0.5, y, 6.3, rh, { fill: i === 5 ? C.accent4 : C.background2, name: "take-" + i });
    chip(s, i + 1, 0.6, y + 0.1, 0.36, 0.36, { fill: i === 5 ? C.accent2 : C.accent1, fontSize: 11 });
    s.addText(h, { x: 1.08, y: y + 0.04, w: 1.75, h: rh - 0.08, fontSize: 11, bold: true, color: C.text2, margin: 0, isTextBox: true, valign: "middle", objectName: "take-head" });
    s.addText(b, { x: 2.9, y: y + 0.04, w: 3.8, h: rh - 0.08, fontSize: 10, color: C.text1, margin: 0, isTextBox: true, valign: "middle", objectName: "take-body" });
  });
  card(s, 7.0, 1.15, 2.5, 3.76, { name: "next" });
  s.addText("Next steps", { x: 7.15, y: 1.25, w: 2.2, h: 0.35, fontSize: 13, bold: true, color: C.text2, margin: 0, isTextBox: true, objectName: "next-head" });
  bullets(s, [
    "Super-individuals, to match how the largest depositors exit (Chapter 2 docking)",
    "Deposit insurance and the reserve ratio on the fire-sale bank",
    "Network topology and learning",
    "Full sweep: stale public signal plus no-signal baseline, CARA 0.1, σ reported",
  ], 7.15, 1.65, 2.2, 3.2, { size: 11, gap: 7 });
  s.addNotes("~2 min. Next steps from the outline: super-individuals (match how Celsius's largest depositors exit), deposit insurance and the reserve ratio on the fire-sale bank, topology and learning, and the full parameter sweep (stale public signal + no-signal baseline; CARA 0.1; sigma reported).");

  // ================= 11. Backup divider =================
  pres.addSection({ title: "Backup" });
  s = pres.addSlide({ masterName: "SECTION", sectionTitle: "Backup" });
  s.addText("Backup", { placeholder: "title" });
  s.addText("Technical versions of the exhibits, the pre-registered tests, channels, and the Celsius docking gap.", { placeholder: "body" });
  s.addNotes("");

  // ---- backup figure slides ----
  function figSlide(title, key, cap, alt, notes, maxH = 3.7) {
    const sl = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Backup" });
    sl.addText(title, { placeholder: "title" });
    const dd = fig(sl, key, 0.5, 1.15, 9.0, maxH, { align: "center", alt });
    caption(sl, cap, 0.5, 1.15 + dd.h + 0.05, 9.0);
    sl.addNotes(notes);
    return sl;
  }
  figSlide("Who withdraws, by type and mix", "e06",
    "Share who withdraw by individualist share μ, one panel per λ pair; orange individualists, blue collectivists, with CIs.",
    "Share who withdraw by individualist share, three panels by lambda pair: collectivists above individualists at every mixed share for the two wide gaps.",
    "Both types withdraw less as mu rises; collectivists above individualists at every mixed mu for the two wide gaps; nearly identical at (0.3, 0.5). Technical labels.");
  figSlide("The pre-registered tests, three versions of the bank", "e03",
    "G1′, G4′, G2a′, G3 and G3c (post hoc). Rows: risk-neutral all-or-nothing, CARA partial, capped reference bank. Filled dot: pooled; hollow: each λ pair. Shaded: Chapter 1’s predicted sign.",
    "Forest plot of five tests (G1', G4', G2a', G3, G3c) across three bank versions with pooled estimates and per-pair markers.",
    "r1k pooled: G1' +0.033, G4' -0.031, G2a' +0.093, all Holm-significant; G2b ordering holds. G3 +0.0034 pooled but (0.3, 0.5) wrong-signed in every bank -> counts against. G3c (post hoc, channel-isolated) +0.019, right-signed in every pair. 3 of 4 confirmatory tests support, in all three banks.");
  figSlide("Which channel carries culture", "e09",
    "D in failed runs with optimistic news, when λ weights only the neighbour blend, only the news blend, or both (the model). θ-blend only +0.14; head-count only −0.07; both +0.02.",
    "Who runs in failed runs with optimistic news when lambda applies only to the neighbour blend, only to the news blend, or both: positive, negative, small positive.",
    "Theta-blend only: +0.14 (Ch 1's sign). Head-count only: -0.07 (opposite). Both: +0.02. The two channels pull in opposite directions; Ch 1's sign survives, damped by herding.");
  figSlide("Matching Celsius: how large depositors exit", "e04",
    "Share of exits that withdraw everything at once, by depositor size. Black: Celsius (band for D1–D5); greys: the model, uncapped and capped.",
    "Share of exits that withdraw everything at once by depositor size: Celsius falls from about 0.86 to 0.35 for the largest; the model stays at 0.93 to 1.",
    "Celsius falls from ~0.86 (D1–D5 band 0.82–0.90) to 0.35 (top 0.1%); the ABM stays at 0.93–1.00. The model does not yet reproduce how large depositors exit. Next: super-individuals.");
  figSlide("Earlier specification (vault bank): failure by mix", "fig1",
    "Vault bank, earlier specification (chapter Figure 1): probability of a run by share of individualists, three λ gaps. Also monotone.",
    "Earlier vault-bank specification: probability of a run falls with the share of individualists for all three signal-weighting gaps.",
    "Vault bank, earlier specification (chapter Fig 1). For questions about Ch 1's P6. This figure is also monotone decreasing: P6 (non-monotonic fragility) was predicted in Ch 1 and found in neither bank; the P6b placebo hump was null too.");

  await pres.writeFile({ fileName: OUT });
  await applyTheme(OUT, THEME);
  console.log("wrote", OUT);
})().catch(e => { console.error(e); process.exit(1); });
