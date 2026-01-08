#!/usr/bin/env node

// 1. Point directly to the compiled JS in mathjax-full
const {mathjax} = require('mathjax-full/js/mathjax.js');
const {TeX} = require('mathjax-full/js/input/tex.js');
const {SVG} = require('mathjax-full/js/output/svg.js');
const {liteAdaptor} = require('mathjax-full/js/adaptors/liteAdaptor.js');
const {RegisterHTMLHandler} = require('mathjax-full/js/handlers/html.js');
const {AllPackages} = require('mathjax-full/js/input/tex/AllPackages.js');

// 2. Load the specific TeX font class
// const { TeXFont } = require('mathjax-full/js/output/svg/fonts/tex.js');

// 3. Setup the DOM Adaptor
const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);

// 4. Capture arguments from Ruby/CLI
const latex = process.argv[2] || '';
const isInline = process.argv[3] === 'inline';
const pixels_per_ex = parseInt(process.argv[4]) || 8;

// 5. Initialize the TeX and SVG engines
const tex = new TeX({packages: AllPackages.filter(p => p !== 'bussproofs')});

const svg = new SVG({
  fontCache: 'local',
  exFactor: 1 / pixels_per_ex,
  //    font: new TeXFont() // Using the font you verified in your directory
});

const html = mathjax.document('', {InputJax: tex, OutputJax: svg});

// 6. Execution
try {
  const node = html.convert(
      latex,
      {display: !isInline, em: 16, ex: pixels_per_ex, containerWidth: 80 * 16});

  const svgString = adaptor.innerHTML(node);
  process.stdout.write(svgString);
} catch (err) {
  process.stderr.write(err.toString());
  process.exit(1);
}
