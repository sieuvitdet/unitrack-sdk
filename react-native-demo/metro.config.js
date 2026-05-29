const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');
const path = require('path');

// @unitrack/react-native lives OUTSIDE this app (../platforms/react-native),
// linked via a `file:` dependency (a symlink). Metro doesn't follow symlinks out
// of the project root by default, so:
//   • watchFolders: let Metro read the SDK package's files
//   • extraNodeModules: resolve the package name to its real path, and make its
//     own react / react-native imports resolve to THIS app's node_modules.
const sdkPath = path.resolve(__dirname, '../platforms/react-native');

const config = {
  watchFolders: [sdkPath],
  resolver: {
    extraNodeModules: new Proxy(
      { '@unitrack/react-native': sdkPath },
      {
        get: (target, name) =>
          name in target
            ? target[name]
            : path.join(__dirname, 'node_modules', String(name)),
      },
    ),
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
