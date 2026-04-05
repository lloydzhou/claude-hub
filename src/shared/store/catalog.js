const CATALOG_SESSION_KEY = 'claude-cluster.current-session';

function createCatalogState() {
  return {
    sessions: [],
    currentSessionId: null,
    loadError: null,
  };
}

export {
  CATALOG_SESSION_KEY,
  createCatalogState,
};
