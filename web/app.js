/* Greater Banjul Access - web map.
   Works against the live API ("api") or pre-exported files ("static", GitHub Pages);
   see config.js. No build step, no framework. */
"use strict";

const CFG = window.APP_CONFIG || { dataSource: "api", apiBase: "/api", staticBase: "data" };
const STATIC = CFG.dataSource === "static";

const STYLE_URL = {
  light: "https://tiles.openfreemap.org/styles/positron",
  dark: "https://tiles.openfreemap.org/styles/dark",
};
const START = { center: [-16.665, 13.415], zoom: 11.2 };

const LABEL = {
  health: { one: "health facility", many: "Health facilities" },
  school: { one: "school", many: "Schools" },
  walk: "walk", drive: "drive",
};

// ---------------------------------------------------------------- state
const state = { type: "health", mode: "walk", minutes: 30, scenario: "base", view: "area" };
const cache = new Map();          // url -> parsed JSON
let META = null, STATS = [], HEX_IDS = [];
let current = { sa: null, gaps: null, surface: null, facilities: null, route: null };
let facilityById = new Map();
let selectedFacility = null;

// ---------------------------------------------------------------- data access
function dataUrl(name, p = {}) {
  if (!STATIC) {
    const qs = new URLSearchParams(p).toString();
    return `${CFG.apiBase}/${name}${qs ? "?" + qs : ""}`;
  }
  const b = CFG.staticBase;
  switch (name) {
    case "meta": return `${b}/meta.json`;
    case "stats": return `${b}/stats.json`;
    case "facilities": return `${b}/facilities_${p.type}.geojson`;
    case "service-areas": return `${b}/service-areas/${p.type}_${p.mode}_${p.scenario}_${p.minutes}.geojson`;
    case "gaps": return `${b}/gaps/${p.type}_${p.mode}_${p.scenario}_${p.minutes}.geojson`;
    case "surface/hexes": return `${b}/surface/hexes.geojson`;
    case "surface": return `${b}/surface/${p.type}_${p.mode}_${p.scenario}.json`;
    default: throw new Error(`No static file for ${name}`);
  }
}

async function getJSON(url) {
  if (cache.has(url)) return cache.get(url);
  const r = await fetch(url);
  if (!r.ok) {
    let detail = `${r.status} ${r.statusText}`;
    try { const j = await r.json(); if (j.detail) detail = typeof j.detail === "string" ? j.detail : JSON.stringify(j.detail); } catch (_) { /* not JSON */ }
    const err = new Error(detail); err.status = r.status; throw err;
  }
  const j = await r.json();
  cache.set(url, j);
  return j;
}

const api = {
  meta: () => getJSON(dataUrl("meta")),
  stats: () => getJSON(dataUrl("stats")),
  facilities: (type) => getJSON(dataUrl("facilities", { type, include_buffer: true })),
  serviceArea: (s) => getJSON(dataUrl("service-areas", { type: s.type, mode: s.mode, minutes: s.minutes, scenario: s.scenario })),
  gaps: (s) => getJSON(dataUrl("gaps", { type: s.type, mode: s.mode, minutes: s.minutes, scenario: s.scenario })),
  hexes: () => getJSON(dataUrl("surface/hexes")),
  surface: (s) => getJSON(dataUrl("surface", { type: s.type, mode: s.mode, scenario: s.scenario })),
  nearest: (lat, lon, s) => {
    const qs = new URLSearchParams({ lat, lon, type: s.type, mode: s.mode, scenario: s.scenario });
    return fetch(`${CFG.apiBase}/nearest?${qs}`).then(async (r) => {
      const j = await r.json().catch(() => ({}));
      if (!r.ok) { const e = new Error(typeof j.detail === "string" ? j.detail : `Error ${r.status}`); e.status = r.status; throw e; }
      return j;
    });
  },
};

// ---------------------------------------------------------------- helpers
const $ = (sel) => document.querySelector(sel);
const fmt = new Intl.NumberFormat("en-GB");
const fmt1 = new Intl.NumberFormat("en-GB", { maximumFractionDigits: 1, minimumFractionDigits: 1 });
const EMPTY = { type: "FeatureCollection", features: [] };

function el(tag, attrs = {}, ...children) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") n.className = v;
    else if (k === "style") n.style.cssText = v;
    else n.setAttribute(k, v);
  }
  for (const c of children) n.append(c instanceof Node ? c : document.createTextNode(String(c)));
  return n;
}
function token(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }
function isDark() {
  const forced = document.documentElement.getAttribute("data-theme");
  if (forced) return forced === "dark";
  return window.matchMedia("(prefers-color-scheme: dark)").matches;
}
function setStatus(text) { $("#status").textContent = text || ""; }
function bands() { return (META && META.bands[state.mode]) || (state.mode === "walk" ? [15, 30, 60] : [5, 10, 15]); }
function bandClass(minutes) {
  const b = bands();
  if (minutes <= b[0]) return 0;
  if (minutes <= b[1]) return 1;
  if (minutes <= b[2]) return 2;
  return 3;
}
function modeWord() { return state.mode === "walk" ? "walk" : "drive"; }

// ---------------------------------------------------------------- map
const map = new maplibregl.Map({
  container: "map",
  style: isDark() ? STYLE_URL.dark : STYLE_URL.light,
  center: START.center,
  zoom: START.zoom,
  attributionControl: { compact: true, customAttribution: "Analysis: OSM, Maina et al. 2019, Google Open Buildings, OCHA COD-AB" },
});
map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "top-right");
map.addControl(new maplibregl.ScaleControl({ unit: "metric" }), "bottom-right");
// The dark basemap style refers to a pattern image its sprite does not contain: give it a
// transparent placeholder instead of a console warning.
map.on("styleimagemissing", (e) => {
  if (!map.hasImage(e.id)) map.addImage(e.id, { width: 1, height: 1, data: new Uint8Array(4) });
});

// Our fills go above every basemap road/area layer and below the labels that follow them.
// (Taking the very first symbol layer is not enough: some styles put a label before the roads,
// and the roads would then be drawn over the data.)
function labelLayerAboveBasemap() {
  const layers = map.getStyle().layers || [];
  let lastShape = -1;
  layers.forEach((l, i) => { if (l.type !== "symbol") lastShape = i; });
  const l = layers.slice(lastShape + 1).find((x) => x.type === "symbol");
  return l ? l.id : undefined;
}

function addLayers() {
  const below = labelLayerAboveBasemap();   // basemap labels stay readable above the fills
  const src = (id, data) => { if (!map.getSource(id)) map.addSource(id, { type: "geojson", data: data || EMPTY }); };

  src("hexes", current.hexes);
  src("sa", current.sa);
  src("gaps", current.gaps);
  src("facilities", current.facilities);
  src("route", current.route);

  map.addLayer({
    id: "hex-fill", type: "fill", source: "hexes",
    paint: {
      "fill-color": ["match", ["coalesce", ["feature-state", "c"], -1],
        0, token("--t0"), 1, token("--t1"), 2, token("--t2"), 3, token("--t3"), token("--no-road")],
      "fill-opacity": ["case", ["==", ["coalesce", ["feature-state", "c"], -1], -1], 0.35, 0.78],
      "fill-outline-color": token("--surface"),
    },
    layout: { visibility: state.view === "surface" ? "visible" : "none" },
  }, below);
  // Invisible but always present: lets a click find its hexagon in the static demo.
  map.addLayer({ id: "hex-hit", type: "fill", source: "hexes", paint: { "fill-opacity": 0 } }, below);

  map.addLayer({ id: "sa-fill", type: "fill", source: "sa", paint: { "fill-color": token("--sa"), "fill-opacity": 0.22 } }, below);
  map.addLayer({ id: "sa-line", type: "line", source: "sa", paint: { "line-color": token("--sa"), "line-width": 1.5 } }, below);
  map.addLayer({ id: "gap-fill", type: "fill", source: "gaps", paint: { "fill-color": token("--gap"), "fill-opacity": 0.38 } }, below);
  map.addLayer({ id: "gap-line", type: "line", source: "gaps", paint: { "line-color": token("--gap"), "line-width": 1 } }, below);

  map.addLayer({
    id: "route-casing", type: "line", source: "route", filter: ["==", ["get", "role"], "route"],
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": token("--route-casing"), "line-width": 7 },
  });
  map.addLayer({
    id: "route-line", type: "line", source: "route", filter: ["==", ["get", "role"], "route"],
    layout: { "line-cap": "round", "line-join": "round" },
    paint: {
      "line-color": token("--route"), "line-width": 3,
      "line-dasharray": ["case", ["==", ["get", "estimate"], true], ["literal", [1.5, 1.5]], ["literal", [1, 0]]],
    },
  });
  map.addLayer({
    id: "facilities", type: "circle", source: "facilities",
    paint: {
      "circle-radius": ["interpolate", ["linear"], ["zoom"], 10, 4.5, 14, 7],
      "circle-color": ["case", ["get", "in_study"], token("--fac"), token("--fac-ring")],
      "circle-stroke-color": ["case", ["get", "in_study"], token("--fac-ring"), token("--fac")],
      "circle-stroke-width": ["case", ["boolean", ["feature-state", "selected"], false], 4, 2],
    },
  });
  map.addLayer({
    id: "origin", type: "circle", source: "route", filter: ["==", ["get", "role"], "origin"],
    paint: { "circle-radius": 6, "circle-color": token("--route-casing"), "circle-stroke-color": token("--route"), "circle-stroke-width": 3 },
  });
  applyView();
}

function setData(id, data) { const s = map.getSource(id); if (s) s.setData(data || EMPTY); }
// The route is kept so it can be redrawn after a theme switch (which reloads the basemap style).
function setRoute(fc) { current.route = fc && fc.features.length ? fc : null; setData("route", current.route); }

function applyView() {
  const area = state.view === "area";
  for (const id of ["sa-fill", "sa-line", "gap-fill", "gap-line"]) {
    if (map.getLayer(id)) map.setLayoutProperty(id, "visibility", area ? "visible" : "none");
  }
  if (map.getLayer("hex-fill")) map.setLayoutProperty("hex-fill", "visibility", area ? "none" : "visible");
}

function paintSurface() {
  if (!current.surface || !map.getSource("hexes")) return;
  const rows = new Map(current.surface.hexes.map((r) => [r[0], r]));
  for (const id of HEX_IDS) {
    const r = rows.get(id);
    map.setFeatureState({ source: "hexes", id }, { c: r ? bandClass(r[1]) : -1 });
  }
}

// ---------------------------------------------------------------- loading
let loadToken = 0;
async function refresh() {
  const my = ++loadToken;
  setStatus("Loading…");
  try {
    const s = { ...state };
    const needSurface = state.view === "surface" || STATIC;
    const [sa, gaps, fac, surface] = await Promise.all([
      api.serviceArea(s), api.gaps(s), api.facilities(s.type), needSurface ? api.surface(s) : Promise.resolve(null),
    ]);
    if (my !== loadToken) return;          // a newer request has started
    current.sa = sa; current.gaps = gaps; current.facilities = fac;
    if (surface) current.surface = surface;
    facilityById = new Map(fac.features.map((f) => [f.id, f]));
    setData("sa", sa); setData("gaps", gaps); setData("facilities", fac);
    if (state.view === "surface") paintSurface();
    applyView();
    renderStats(); renderLegend();
    setStatus("");
  } catch (e) {
    if (my === loadToken) setStatus(`Could not load data: ${e.message}`);
  }
}

// ---------------------------------------------------------------- panel: controls
function renderMinutes() {
  const box = $("#ctl-minutes");
  box.querySelectorAll("label").forEach((n) => n.remove());
  for (const m of bands()) {
    const input = el("input", { type: "radio", name: "minutes", value: String(m) });
    if (m === state.minutes) input.checked = true;
    box.append(el("label", {}, input, el("span", {}, `${m} min`)));
  }
}

function renderScenarios() {
  const sel = $("#ctl-scenario");
  sel.replaceChildren();
  const list = (META ? META.scenarios : [{ scenario: "base", applies_to: "both", description: "Base assumptions" }])
    .filter((s) => s.applies_to === "both" || s.applies_to === state.mode);
  for (const s of list) {
    const label = s.scenario === "base" ? "Base speeds"
      : s.scenario === "walk_slow" ? `Slower walking (${s.walk_kmh} km/h)`
      : s.scenario === "walk_fast" ? `Faster walking (${s.walk_kmh} km/h)`
      : s.scenario === "drive_congested" ? `Congested driving (× ${s.drive_factor})`
      : s.description || s.scenario;
    sel.append(el("option", { value: s.scenario }, label));
  }
  if (!list.some((s) => s.scenario === state.scenario)) state.scenario = "base";
  sel.value = state.scenario;
}

function onControlChange(e) {
  const t = e.target;
  if (t.name === "mode" && t.value !== state.mode) {
    const idx = bands().indexOf(state.minutes);
    state.mode = t.value;
    state.minutes = bands()[idx >= 0 ? idx : 1];   // keep the same position (short / mid / long)
    renderMinutes(); renderScenarios();
  } else if (t.name === "type") state.type = t.value;
  else if (t.name === "minutes") state.minutes = Number(t.value);
  else if (t.name === "scenario") state.scenario = t.value;
  else if (t.name === "view") state.view = t.value;
  clearNearest();
  refresh();
}

// ---------------------------------------------------------------- panel: stats, bars, legend
function statRow(minutes) {
  return STATS.find((r) => r.type === state.type && r.mode === state.mode && r.scenario === state.scenario && r.minutes === minutes);
}

function renderStats() {
  const row = statRow(state.minutes);
  if (!row) { $("#hero-value").textContent = "–"; $("#hero-text").textContent = ""; return; }
  $("#hero-value").textContent = `${fmt1.format(row.pct)} %`;
  $("#hero-text").textContent =
    `of buildings are within a ${state.minutes}-minute ${modeWord()} of a ${LABEL[state.type].one}` +
    (state.scenario === "base" ? "." : ` (${$("#ctl-scenario").selectedOptions[0]?.textContent.toLowerCase()}).`);
  const out = row.buildings_total - row.buildings_in;
  const nGaps = current.gaps ? current.gaps.features.filter((f) => f.properties.n_buildings > 0).length : 0;
  $("#gap-text").textContent = `${fmt.format(out)} buildings are further away, in ${fmt.format(nGaps)} separate areas.`;

  const box = $("#bars");
  box.replaceChildren();
  for (const m of bands()) {
    const r = statRow(m);
    if (!r) continue;
    const b = el("button", { class: "bar", type: "button", "aria-pressed": String(m === state.minutes),
      title: `${fmt.format(r.buildings_in)} of ${fmt.format(r.buildings_total)} buildings` },
      el("span", {}, `${m} min`),
      el("span", { class: "track" }, el("span", { class: "fill", style: `width:${r.pct}%` })),
      el("span", { class: "val" }, `${fmt1.format(r.pct)} %`));
    b.addEventListener("click", () => {
      state.minutes = m;
      const input = document.querySelector(`input[name=minutes][value="${m}"]`);
      if (input) input.checked = true;
      clearNearest(); refresh();
    });
    box.append(b);
  }
}

function renderLegend() {
  const ul = $("#legend");
  ul.replaceChildren();
  const item = (sw, text) => ul.append(el("li", {}, sw, el("span", {}, text)));
  const b = bands();
  if (state.view === "area") {
    item(el("span", { class: "sw", style: `background:${token("--sa")};opacity:.55` }), `Within ${state.minutes} min (${modeWord()})`);
    item(el("span", { class: "sw", style: `background:${token("--gap")};opacity:.7` }), `Further than ${state.minutes} min (gap)`);
  } else {
    const labels = [`up to ${b[0]} min`, `${b[0]}–${b[1]} min`, `${b[1]}–${b[2]} min`, `over ${b[2]} min`];
    labels.forEach((t, i) => item(el("span", { class: "sw", style: `background:${token(`--t${i}`)}` }), t));
    item(el("span", { class: "sw", style: `background:${token("--no-road")};opacity:.6` }), "No road within 150 m");
  }
  item(el("span", { class: "sw dot", style: `background:${token("--fac")}` }), LABEL[state.type].many);
  item(el("span", { class: "sw ring" }), "Facility outside the study area (within 5 km)");
}

// ---------------------------------------------------------------- nearest
function clearNearest() {
  setRoute(null);
  if (selectedFacility != null && map.getSource("facilities")) {
    map.setFeatureState({ source: "facilities", id: selectedFacility }, { selected: false });
  }
  selectedFacility = null;
  $("#nearest").replaceChildren(el("p", { class: "hint" }, "Click the map to find the nearest facility and the route to it."));
}

function showNearestCard({ name, subtype, minutes, distance, snap, note }) {
  const box = $("#nearest");
  box.replaceChildren(
    el("p", { class: "card-title" }, name || `Unnamed ${subtype || LABEL[state.type].one}`),
    el("p", { class: "card-big" }, `${fmt1.format(minutes)} min ${modeWord()}`),
    el("p", { class: "card-row" }, [subtype ? subtype.replace("_", " ") : null, distance != null ? `${fmt.format(Math.round(distance))} m by road` : null].filter(Boolean).join(" · ")),
  );
  if (snap != null) box.append(el("p", { class: "card-note" }, `Starts from the nearest road, ${fmt.format(Math.round(snap))} m from where you clicked (not included in the time).`));
  if (note) box.append(el("p", { class: "card-note" }, note));
  box.scrollIntoView({ block: "nearest", behavior: "smooth" });
}

function selectFacility(id) {
  if (selectedFacility != null) map.setFeatureState({ source: "facilities", id: selectedFacility }, { selected: false });
  selectedFacility = id;
  if (id != null) map.setFeatureState({ source: "facilities", id }, { selected: true });
}

async function onMapClick(e) {
  const { lng, lat } = e.lngLat;
  if (STATIC) return staticNearest(e);
  $("#nearest").replaceChildren(el("p", { class: "hint" }, "Finding the nearest facility…"));
  try {
    const fc = await api.nearest(lat.toFixed(6), lng.toFixed(6), state);
    const by = Object.fromEntries(fc.features.map((f) => [f.properties.role, f]));
    setRoute({ type: "FeatureCollection", features: [by.route, by.origin].filter((f) => f && f.geometry) });
    selectFacility(by.facility.id);
    showNearestCard({
      name: by.facility.properties.name, subtype: by.facility.properties.subtype,
      minutes: by.route.properties.minutes, distance: by.route.properties.distance_m, snap: by.origin.properties.snap_m,
    });
  } catch (err) {
    setRoute(null); selectFacility(null);
    $("#nearest").replaceChildren(el("p", { class: "error" }, err.message));
  }
}

async function staticNearest(e) {
  // Static demo: no routing server. Use the pre-computed hexagon under the click.
  const hit = map.queryRenderedFeatures(e.point, { layers: ["hex-hit"] })[0];
  if (!hit) { $("#nearest").replaceChildren(el("p", { class: "error" }, "Click on land inside the study area.")); return; }
  current.surface = current.surface || await api.surface(state);
  const row = current.surface.hexes.find((r) => r[0] === hit.id);
  if (!row) { $("#nearest").replaceChildren(el("p", { class: "error" }, "No road within 150 m of this area.")); return; }
  const fac = facilityById.get(row[2]);
  const origin = { type: "Feature", properties: { role: "origin" }, geometry: { type: "Point", coordinates: [e.lngLat.lng, e.lngLat.lat] } };
  const line = fac ? { type: "Feature", properties: { role: "route", estimate: true },
    geometry: { type: "LineString", coordinates: [[e.lngLat.lng, e.lngLat.lat], fac.geometry.coordinates] } } : null;
  setRoute({ type: "FeatureCollection", features: [line, origin].filter(Boolean) });
  selectFacility(fac ? fac.id : null);
  showNearestCard({
    name: fac?.properties.name, subtype: fac?.properties.subtype, minutes: row[1],
    note: "Static demo: typical time for this 200 m area, from the pre-computed travel-time surface. The dashed line is not the route; run the full version for exact routes.",
  });
}

// ---------------------------------------------------------------- tooltips
const tip = $("#tooltip");
function showTip(e, html) {
  tip.replaceChildren(...html);
  tip.hidden = false;
  const x = e.originalEvent.clientX, y = e.originalEvent.clientY;
  const w = tip.offsetWidth, h = tip.offsetHeight;
  tip.style.left = `${Math.min(x + 14, window.innerWidth - w - 8)}px`;
  tip.style.top = `${Math.min(y + 14, window.innerHeight - h - 8)}px`;
}
function hideTip() { tip.hidden = true; }

function bindHover() {
  map.on("mousemove", "facilities", (e) => {
    map.getCanvas().style.cursor = "pointer";
    const p = e.features[0].properties;
    showTip(e, [el("strong", {}, p.name && p.name !== "null" ? p.name : `Unnamed ${p.subtype}`),
      el("span", {}, `${String(p.subtype).replace("_", " ")}${p.source === "maina2019" ? " · public facility list" : ""}`)]);
  });
  map.on("mouseleave", "facilities", () => { map.getCanvas().style.cursor = ""; hideTip(); });

  map.on("mousemove", "hex-fill", (e) => {
    if (map.queryRenderedFeatures(e.point, { layers: ["facilities"] }).length) return;
    const f = e.features[0];
    const row = current.surface?.hexes.find((r) => r[0] === f.id);
    const fac = row ? facilityById.get(row[2]) : null;
    showTip(e, [
      el("strong", {}, row ? `${fmt1.format(row[1])} min ${modeWord()}` : "No road within 150 m"),
      el("span", {}, `${fmt.format(f.properties.n_buildings)} buildings${fac?.properties.name ? ` · nearest: ${fac.properties.name}` : ""}`),
    ]);
  });
  map.on("mouseleave", "hex-fill", hideTip);

  map.on("mousemove", "gap-fill", (e) => {
    if (map.queryRenderedFeatures(e.point, { layers: ["facilities"] }).length) return;
    const p = e.features[0].properties;
    showTip(e, [el("strong", {}, `${fmt.format(p.n_buildings)} buildings`),
      el("span", {}, `${fmt1.format(p.area_km2)} km² further than ${p.minutes} min`)]);
  });
  map.on("mouseleave", "gap-fill", hideTip);
}

// ---------------------------------------------------------------- theme
// Three choices: "auto" follows the system setting, "light" and "dark" override it.
// The choice is a per-browser convenience kept in localStorage (it may be unavailable).
const THEMES = ["auto", "light", "dark"];
const THEME_LABEL = { auto: "automatic", light: "light", dark: "dark" };
let themeChoice = (() => { try { return THEMES.includes(localStorage.getItem("theme")) ? localStorage.getItem("theme") : "auto"; } catch (_) { return "auto"; } })();
let mapIsDark = isDark();

function showThemeButton() {
  const btn = $("#theme");
  // SVG elements have no .hidden property: set the attribute itself.
  btn.querySelectorAll("svg").forEach((svg) => svg.toggleAttribute("hidden", svg.dataset.icon !== themeChoice));
  const next = THEMES[(THEMES.indexOf(themeChoice) + 1) % THEMES.length];
  btn.title = `Colour theme: ${THEME_LABEL[themeChoice]} (click for ${THEME_LABEL[next]})`;
  btn.setAttribute("aria-label", `Colour theme: ${THEME_LABEL[themeChoice]}`);
}

function setTheme(choice) {
  themeChoice = choice;
  if (choice === "auto") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", choice);
  try { localStorage.setItem("theme", choice); } catch (_) { /* private mode: not remembered */ }
  showThemeButton();
  restyle();
}

// Swap the basemap (and our layer colours) only when light/dark actually changes.
function restyle() {
  const dark = isDark();
  renderLegend();
  if (dark === mapIsDark) return;
  mapIsDark = dark;
  map.setStyle(dark ? STYLE_URL.dark : STYLE_URL.light);
  map.once("style.load", () => {
    addLayers(); paintSurface();
    if (selectedFacility != null) selectFacility(selectedFacility);
  });
}
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { if (themeChoice === "auto") restyle(); });

// ---------------------------------------------------------------- start
async function start() {
  $("#controls").addEventListener("change", onControlChange);
  showThemeButton();
  $("#theme").addEventListener("click", () => setTheme(THEMES[(THEMES.indexOf(themeChoice) + 1) % THEMES.length]));
  $("#collapse").addEventListener("click", () => {
    const p = $("#panel"); const c = p.classList.toggle("collapsed");
    $("#collapse").setAttribute("aria-expanded", String(!c));
  });
  $("#docs-link").href = STATIC ? "api-docs.html" : `${location.protocol}//${location.hostname}:8000/docs`;

  try {
    [META, STATS] = await Promise.all([api.meta(), api.stats()]);
    const osm = META.datasets.find((d) => d.name === "osm");
    if (osm?.data_date) $("#data-date").textContent = `OSM data of ${osm.data_date.slice(0, 10)}.`;
  } catch (e) {
    setStatus(`Could not reach the data: ${e.message}`);
  }
  renderMinutes(); renderScenarios();

  const hexes = await api.hexes().catch(() => EMPTY);
  current.hexes = hexes;
  HEX_IDS = hexes.features.map((f) => f.id);

  const ready = () => {
    addLayers();
    bindHover();
    map.on("click", onMapClick);
    if (hexes.features.length) {
      const bbox = hexes.features.reduce((b, f) => {
        for (const poly of f.geometry.coordinates) for (const ring of poly) for (const [x, y] of ring) {
          b[0] = Math.min(b[0], x); b[1] = Math.min(b[1], y); b[2] = Math.max(b[2], x); b[3] = Math.max(b[3], y);
        }
        return b;
      }, [180, 90, -180, -90]);
      const narrow = window.innerWidth <= 720;
      map.fitBounds([[bbox[0], bbox[1]], [bbox[2], bbox[3]]], {
        padding: narrow ? { top: 20, bottom: window.innerHeight * 0.45, left: 20, right: 20 } : { top: 40, bottom: 40, left: 400, right: 60 },
        duration: 0,
      });
    }
    refresh();
  };
  if (map.isStyleLoaded()) ready(); else map.once("load", ready);
}
start();
