import { createCatalogState, createRuntimeState, CATALOG_SESSION_KEY } from '../../shared/store/index.js';

function createBrowserStore() {
  return {
    catalog: createCatalogState(),
    runtime: createRuntimeState(),
    storageKey: CATALOG_SESSION_KEY,
  };
}

export {
  createBrowserStore,
};
