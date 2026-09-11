import resolve from '@rollup/plugin-node-resolve';

export default {
  input: 'src/bridge.js',
  output: {
    file: '../assets/js/yjs_bridge.js',
    format: 'iife',
    name: 'YjsProbeBridge',
  },
  plugins: [resolve()],
};
