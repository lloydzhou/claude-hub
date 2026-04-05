import { createCatalogState, createRuntimeState } from '../../shared/store/index.js';

function createNodeStore() {
  return {
    catalog: createCatalogState(),
    runtime: createRuntimeState(),
  };
}

export {
  createNodeStore,
};
