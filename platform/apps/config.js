// Overwritten at build time with the deployed Cloud Run URL.
// Each app's cloudbuild.yaml writes its own service URL here as
// window.API_BASE_<APP> so multiple Cloud Run services can coexist.
window.API_BASE = "";
