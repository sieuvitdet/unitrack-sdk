import typescript from '@rollup/plugin-typescript';

const banner = `/*! @unitrack/web v0.1.0 — https://github.com/sieuvitdet/unitrack-sdk */`;

export default {
  input: 'src/index.ts',
  output: [
    {
      file: 'dist/unitrack.cjs.js',
      format: 'cjs',
      sourcemap: true,
      exports: 'named',
      banner,
    },
    {
      file: 'dist/unitrack.esm.js',
      format: 'esm',
      sourcemap: true,
      exports: 'named',
      banner,
    },
    // IIFE for <script> tag — expose global `UniTrack`.
    {
      file: 'dist/unitrack.iife.js',
      format: 'iife',
      name: 'UniTrack',
      sourcemap: true,
      banner,
      // Flatten the namespace: `UniTrack.UniTrack.initialize(...)` → `UniTrack.initialize(...)`
      footer: 'if (typeof window !== "undefined" && window.UniTrack && window.UniTrack.UniTrack) { window.UniTrack = Object.assign(window.UniTrack.UniTrack, window.UniTrack); }',
    },
  ],
  plugins: [
    typescript({
      tsconfig: './tsconfig.json',
      sourceMap: true,
      declarationMap: false,
    }),
  ],
};
