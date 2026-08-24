import typescript from '@rollup/plugin-typescript';

const banner = `/*! unitrack-web v0.2.0 — https://github.com/sieuvitdet/unitrack-sdk */`;

export default {
  input: 'src/index.ts',
  output: [
    {
      file: 'dist/unitrack.cjs.js',
      format: 'cjs',
      sourcemap: true,
      exports: 'named',
      banner,
      // `exports: 'named'` bỏ mất default export, nên `require('unitrack-web')`
      // trả namespace chứ không phải instance — `.initializeFromConfig` thành
      // undefined. Gộp named export lên chính instance để cả hai lối dùng đều
      // chạy: `require(...)` ra instance, `.HttpProvider` vẫn lấy được.
      footer: 'module.exports = Object.assign(exports.UniTrack, exports);',
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
