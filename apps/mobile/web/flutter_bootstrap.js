{{flutter_js}}
{{flutter_build_config}}

// Offline-first: load from SW cache first, then network
_flutter.loader.load({
  serviceWorker: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
  onEntrypointLoaded: async function(engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine({
      // Use the JS renderer (no CanvasKit WASM download)
      renderer: 'html',
    });
    await appRunner.runApp();
  }
});
