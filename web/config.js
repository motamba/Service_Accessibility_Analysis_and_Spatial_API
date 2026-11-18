// Where the map gets its data.
//   "api"    : the live API through the same web server (/api/...), used by `docker compose up`
//   "static" : pre-exported files in ./data, used by the GitHub Pages demo (no backend)
window.APP_CONFIG = {
  dataSource: "api",
  apiBase: "/api",
  staticBase: "data",
};
