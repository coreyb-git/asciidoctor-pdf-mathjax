# Asciidoctor PDF MathJax

![GitHub License](https://img.shields.io/github/license/Crown0815/asciidoctor-pdf-mathjax)
![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/Crown0815/asciidoctor-pdf-mathjax/build-and-release.yaml?branch=main)
![GitHub Last Commit](https://img.shields.io/github/last-commit/Crown0815/asciidoctor-pdf-mathjax)
![GitHub Issues](https://img.shields.io/github/issues/Crown0815/asciidoctor-pdf-mathjax)
![GitHub Release](https://img.shields.io/github/v/release/Crown0815/asciidoctor-pdf-mathjax)

An extension for [Asciidoctor PDF](https://github.com/asciidoctor/asciidoctor-pdf) that
integrates [MathJax](https://www.mathjax.org/) to render mathematical expressions in PDF output.

This Ruby gem enhances the [asciidoctor-pdf](https://github.com/asciidoctor/asciidoctor-pdf) converter by enabling
high-quality rendering of STEM (Science, Technology, Engineering, and Math) content
using [MathJax](https://www.mathjax.org/).
It processes AsciiDoc documents with mathematical notation (e.g., AsciiMath or LaTeX) and outputs them as beautifully
formatted equations in the resulting PDF.

## Features

- **Seamless MathJax Integration**: Converts AsciiMath and LaTeX expressions into SVG or raster images compatible with Asciidoctor PDF.
- **Cross-Platform Support**: Works with Asciidoctor’s PDF backend to produce consistent output across platforms.
- **Support for Inline and Block Equations**: Render both [inline](https://docs.asciidoctor.org/asciidoc/latest/stem/#inline) and [block](https://docs.asciidoctor.org/asciidoc/latest/stem/#block) STEM content effortlessly.
- **High Quality STEM Rendering**: Utilizes MathJax’s powerful rendering engine to produce high-quality STEM content in
  PDF output.
- Cached SVG files (when configured) to ensure rapid .adoc build times.

## Installation Using Docker

Using the following Dockerfile with Docker or Podman to build a ready-to-go image

```Dockerfile
FROM asciidoctor/docker-asciidoctor:1.82

WORKDIR /documents

RUN apk add --upgrade nodejs npm
RUN npm install -g mathjax-node
ENV NODE_PATH=/usr/local/lib/node_modules
RUN gem install asciidoctor-pdf-mathjax

ENTRYPOINT ["bash", "-c", "exec \"$@\"", "--"]
```

To build the image with Podman:

```sh
podman build -t <Your Image Name>
```

## Installation (Manual Setup)

### Prerequisites

- [Ruby](https://www.ruby-lang.org/) 2.7 or higher
- [Asciidoctor](https://asciidoctor.org/) and [Asciidoctor PDF](https://github.com/asciidoctor/asciidoctor-pdf) ([installation instructions](https://github.com/asciidoctor/asciidoctor-pdf?tab=readme-ov-file#prerequisites))
- [NodeJS](https://nodejs.org/en)
- [MathJax Node](https://github.com/mathjax/MathJax-node) (required for PDF generation with LaTeX).
  Install it globally with
  ```sh
  npm install -g mathjax-node
  ```

A good starting point is using the [Asciidoctor Docker Container](https://github.com/asciidoctor/docker-asciidoctor), which comes with most dependencies pre-installed.
You can find an example of a docker container configuration for Asciidoctor PDF MathJax in [this Dockerfile](test/Dockerfile).

### Installation from RubyGems

1. The `asciidoctor-pdf-mathjax` gem is available on RubyGems at https://rubygems.org/gems/asciidoctor-pdf-mathjax.
   To install it:
   ```shell
   ruby -v
   ```

   If Ruby isn’t installed, visit ruby-lang.org for installation instructions.
2. Install the `asciidoctor-pdf-mathjax` gem:
   ```shell
   gem install asciidoctor-pdf-mathjax
   ```
   This command fetches and installs the latest version of asciidoctor-pdf-mathjax along with its dependencies.
3. Verify the installation by running:
   ```shell
   gem list asciidoctor-pdf-mathjax
   ```
   You should see asciidoctor-pdf-mathjax listed with its installed version.

## Usage

To use asciidoctor-pdf-mathjax, you need to require it as an extension when running asciidoctor-pdf and ensure your
AsciiDoc document specifies the `:stem:` attribute.

### Example Asciidoctor PDF Call

Here’s how to convert an AsciiDoc file with mathematical content to PDF using this gem:

1. Create an AsciiDoc file (e.g., `mathdoc.adoc`) with STEM content:
   ```asciidoc
   = Document with Math
   :stem:
   :math-cache-dir: <Your Cache Dir>

   This document includes an equation: stem:[E = mc^2].

   [stem]
   ++++
   \int_0^\infty e^{-x} \, dx = 1
   ++++
   ```

> [!IMPORTANT]
> Don't forget to set the cache directory attribute to a location on your HDD where you want the cached SVG image files to live.  Without this attribute set the SVG images temporary, regenerated each time you build your adoc file, and then destroyed once the SVG data has been embedded into the output PDF.
>
> Also, be aware that the first blank line signals the end of the header/settings.  Ensure any attributes you wish to
> set for your adoc are all above the first blank line.

2. Run the `asciidoctor-pdf` command with the extension:
   ```shell
   asciidoctor-pdf -r asciidoctor-pdf-mathjax mathdoc.adoc -o mathdoc.pdf
   ```

   You can also set the cache directory attribute on the command line, instead of within the adoc file:

   ```shell
   asciidoctor-pdf -a math-cache-dir=<Your Cache Dir> -r asciidoctor-pdf-mathjax mathdoc.adoc -o mathdoc.pdfj
   ```

   - `-a math-cache-dir=<Your Cache Dir>`: Specifies where you want the SVG images to be cached.
   - `-r asciidoctor-pdf-mathjax`: Loads the extension.
   - `mathdoc.adoc`: The input AsciiDoc file.
   - `-o mathdoc.pdf`: The output PDF file.

3. Check the output: Open `mathdoc.pdf` to see the rendered equations (e.g., $E=mc^2$ and the integral) in high-quality
   typesetting.

#### Notes

- The `:stem:` attribute must be set in the document header or via the `-a stem` flag to enable STEM processing.
- Both inline (`stem:[...]` or `latexmath:[...]`) and block (`[stem]`) STEM content are supported.
- Ensure your system has internet access during the first run, as MathJax may need to fetch resources required for
  rendering MathJax and LaTeX (subsequent runs can work offline).

#### Supported Fonts

By setting the `:math-font: <Font Name>` attribute in the heading of your adoc file, or with `-a math-font=<Font Name>` on the command line, you can choose the font you prefer.  Available fonts in MathJax v2 are:

- TeX: The default Computer Modern look (like standard LaTeX).
- STIX-Web: Professional and academic.
- Asana-Math: Based on the Asana font; a slightly more "ornate" serif style.
- Neo-Euler: An upright, "hand-drawn" math style (designed by Hermann Zapf).
- Gyre-Pagella: A Palatino-based math font; very elegant for book publishing.
- Gyre-Termes: A Times-based math font; very compact.
- Latin-Modern: A modernized version of the classic TeX Computer Modern.

## Issues

Found a bug or have a suggestion? Please open an issue on the [GitHub Issues page](https://github.com/Crown0815/asciidoctor-pdf-mathjax/issues).

### Known Issues

- Inline superscripts crop at the top.  Use block math expressions.
- High inline math expressions may be cropped at the bottom due to the alignment logic.
  To avoid this, consider using block math expressions.
- For very high inline math expressions, asciidoctor-pdf will align them to the bottom of the text, which is undesired.
  To avoid this, consider using block math expressions,
  or [raise an issue in asciiidoctor-pdf](https://github.com/asciidoctor/asciidoctor-pdf/issues).

## Equation alignment background

![alignment-logic.png](alignment-logic.excalidraw.png)

## Contributing

To set up your development environment to run the test you need to install the following:

- [Ruby](https://www.ruby-lang.org/) 3.4 or higher
- [NodeJS](https://nodejs.org/en)
- [diff-pdf](https://github.com/vslavik/diff-pdf)

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Acknowledgements

- [Asciidoctor](https://asciidoctor.org/) and [Asciidoctor PDF](https://github.com/asciidoctor/asciidoctor-pdf) for the
  powerful document conversion framework.
- [MathJax](https://www.mathjax.org/) for its exceptional math rendering engine.
- The open-source community for continuous inspiration and support.
