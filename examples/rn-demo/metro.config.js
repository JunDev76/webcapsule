const path = require('node:path');
const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');

/**
 * Metro configuration
 * https://reactnative.dev/docs/metro
 *
 * @type {import('metro-config').MetroConfig}
 */
// pnpm installs a second react-native copy for the workspace package's own
// devDependencies. Bundling both copies splits ReactNativeViewConfigRegistry,
// so native components registered by the library become invisible to the app.
// Force every request to resolve against this app's single copy.
const singletons = {
  react: path.dirname(require.resolve('react/package.json')),
  'react-native': path.dirname(require.resolve('react-native/package.json')),
};

const config = {
  watchFolders: [path.resolve(__dirname, '../..')],
  resolver: {
    unstable_enableSymlinks: true,
    nodeModulesPaths: [
      path.resolve(__dirname, 'node_modules'),
      path.resolve(__dirname, '../../node_modules'),
    ],
    resolveRequest: (context, moduleName, platform) => {
      for (const [name, root] of Object.entries(singletons)) {
        if (moduleName === name || moduleName.startsWith(`${name}/`)) {
          return context.resolveRequest(
            context,
            path.join(root, moduleName.slice(name.length)),
            platform,
          );
        }
      }
      return context.resolveRequest(context, moduleName, platform);
    },
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
