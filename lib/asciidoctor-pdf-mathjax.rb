# FIXME: Level 0 headings need a different, or no, prefix.  Tall SVG's push Title headings away from the top of the document (no margin?)
# FIXME: Block stem can encroach into the footer.

# TODO: Add ability to select custom MathJax v4 font.
# TODO: When Level 0 headings are fixed, generate /test/verification PDF.
# TODO: Update README.md
# TODO: Find method used for creating unbreakable images that will migrate to a new page if they reach the footer.

require 'asciidoctor-pdf' unless Asciidoctor::Converter.for 'pdf'
require 'open3'
require 'tempfile'
require 'rexml/document'
require 'ttfunk'
require 'asciimath'

require 'digest'

FALLBACK_FONT_SIZE = 12
FALLBACK_FONT_STYLE = 'normal'
FALLBACK_FONT_FAMILY = 'Arial'
FALLBACK_FONT_COLOR = '#000000'

POINTS_PER_EX = 6
REFERENCE_FONT_SIZE = 12

DEFAULT_FONT_SIZE = 12

MATHJAX_DEFAULT_COLOR_STRING = 'currentColor'.freeze
MATHJAX_DEFAULT_FONT_FAMILY = 'mathjax-newcm'.freeze

ATTRIBUTE_FONT = 'math-font'.freeze
ATTRIBUTE_CACHE_DIR = 'math-cache-dir'.freeze

PREFIX_STEM = 'stem-'.freeze
PREFIX_WIDTH = 'width-'.freeze # viewbox width cache files

##### Normalize the height of the SVG image. #####
# Prawn vertically centers SVG's, until the bottom of the image reaches the descender height.
# Therefore, images are centered, or anchored at the descender height.
# Images that are larger than the distance from the descender to the cap height anchor
# at the descender height and continue to expand upwards, depending on the content of the SVG.
# This portion above the ascent overlays the content above it, and does not enforce a gap.
#
# EXCEPTION: It is noted that Abstract Headings break this gap rule with the default theme,
# and they DO enforce a minimum gap between themselves and the content above it.
# ATM I'm not able to detect if a heading is abstract or not, so the font size inherits from
# regular headings which is likely different to abstract headings.
# !!! Don't use LaTeX in abstract headings !!!
#
# With the exception of abstract headings, by including vphantom LaTeX that almost perfectly
# aligns the image between the descent and ascent the normal LaTeX content within the SVG
# will have its baseline aligned with the surrounding text within the paragraph/heading.
# Some discrepancies may arise between different fonts, and the heights are not guaranteed to
# match, but at least the baselines will be close, and standard (no up/down drift depending on
# the LaTeX).  If the pdf theme font has particularly thick strokes, or is otherwise sized
# slightly different the scaling attributes can be set to tweak the size of the SVG within
# the pdf.
#
# An integral with brackets at the subscript, and a \vec A as the superscript, seem to perfectly
# span between the descent and ascent, and aligning y=0 to the baseline, thus normalizing
# the content, unless the LaTeX has subscripts that go deeper than 3 levels.
#
# EXCEPTION: Fonts like Crimson Pro seem to have a wildly different set of dimensions
# requiring a different normalization prefix that has a smaller descender area.
# :math-alt-norm: requests a prefix with a small descender.
#
# This is how I understand it, based on observations.
# - Corey B

VPHANTOM_BASE = '\int_{()}^{\vec A}'.freeze
VPHANTOM_LATEX = "\\vphantom{#{VPHANTOM_BASE}}".freeze

VPHANTOM_ALT_BASE = 'y\int^{I}'.freeze
VPHANTOM_ALT_LATEX = "\\vphantom{#{VPHANTOM_ALT_BASE}}".freeze

ATTRIBUTE_ALT_NORM = 'math-alt-norm'
#####

# Custom prefix
ATTRIBUTE_CUSTOM_NORM = 'math-custom-norm'

# Debug set adds background to svg and doesn't hide the vphantom prefix.
# Debug == 2 doesn't include any phantom text, but still colors.
ATTRIBUTE_DEBUG = 'math-debug'.freeze
ATTRIBUTE_DEBUG_COLOR = 'math-debug-color'.freeze

ATTRIBUTE_INLINE_HEADING_SCALE = 'math-inline-heading-scale'.freeze
ATTRIBUTE_INLINE_BODY_SCALE = 'math-inline-body-scale'.freeze
ATTRIBUTE_BODY_SCALE = 'math-body-scale'.freeze
SCALE_INLINE_HEADING_DEFAULT = 1.0
SCALE_INLINE_BODY_DEFAULT = 1.0
SCALE_BODY_DEFAULT = 1.0

module MathjaxToSVGExtension
  Result_struct = Struct.new(:latex_content, :svg_font_name, :svg_width, :svg_file_path, :temp_file_handle)

  class MathjaxService
    @@cached_svg_viewbox_width = {}
    @@cache_dir_init_done = false

    def get_svg_info(node, is_inline)
      r = Result_struct.new('', '', '', '', nil)

      r.svg_font_name = get_math_font_name # part of final log when embedding into pdf

      temp_latex_content = get_latex_from_node(node, is_inline)

      return r, nil if temp_latex_content.nil?

      L("+++ Processing LaTeX: \n#{temp_latex_content}")

      debugging = get_debug_level(node)

      # Configure the normalization prefix
      norm_prefix_hidden = VPHANTOM_LATEX
      norm_prefix_visible = VPHANTOM_BASE
      if node.document.attributes[ATTRIBUTE_ALT_NORM]
        norm_prefix_hidden = VPHANTOM_ALT_LATEX
        norm_prefix_visible = VPHANTOM_ALT_BASE
      end
      if node.document.attributes[ATTRIBUTE_CUSTOM_NORM]
        norm_prefix_visible = node.document.attributes[ATTRIBUTE_CUSTOM_NORM]
        norm_prefix_hidden = "\vphantom{#{norm_prefix_hidden}}"
      end

      if is_inline
        # Normalize inline SVG alignment of characters
        temp_inline = norm_prefix_hidden

        case debugging
        when 1
          # Just color the SVG. Don't show phantom prefix.
          # This reveals the default positioning and boundaries of SVG's.
        when 2
          # Show the prefix in the output to view the alignment, and color SVG.
          temp_inline = norm_prefix_visible
        when 3
          # Don't apply any prefix. Native alignment instead.  Debug coloring only.
          temp_inline = ''
        end

        temp_latex_content = temp_inline + temp_latex_content
      end

      r.latex_content = temp_latex_content

      font_data = get_font_from_context(node)

      hash_key = get_hash_key(r.latex_content, r.svg_font_name, is_inline, debugging)

      cache_dir = get_cache_dir(node)
      unless cache_dir.nil? # caching enabled
        unless @@cache_dir_init_done # ensure directory exists
          L('INIT cache dir: ' + cache_dir)
          @@cache_dir_init_done = true
          FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)
        end

        r.svg_file_path = get_cached_svg_file_path(cache_dir, hash_key)

        if File.exist?(r.svg_file_path)
          viewbox_width = get_cached_svg_viewbox_width(cache_dir, hash_key)
          r.svg_width = get_scaled_svg_width(node, font_data[:font_size], viewbox_width, is_inline)
          L('Returning previously cached file and scaled width.')
          return r
        end
      end

      # caching disabled, or file doesn't exist in cache yet, so create
      L('CREATING SVG for hash: ' + hash_key + ' -- Latex content: ' + r.latex_content)

      adjusted_svg, error = get_adjusted_svg_and_set_cached_width(node, r.latex_content, is_inline, hash_key)
      return r, error if error

      svg_output = adjusted_svg[:svg_output]
      viewbox_width = adjusted_svg[:svg_viewbox_width]

      r.svg_width = get_scaled_svg_width(node, font_data[:font_size], viewbox_width, is_inline)

      unless cache_dir.nil? # cache to disk the width data
        L('Writing viewbox width to RAM')
        @@cached_svg_viewbox_width[hash_key] = viewbox_width

        L("Writing svg content and viewbox width to DISK @  #{r.svg_file_path}")
        File.write(r.svg_file_path, svg_output)
        cached_svg_width_file_path = get_cached_svg_width_path(cache_dir, hash_key)
        File.write(cached_svg_width_file_path, viewbox_width)

        L('returning NEWLY CACHED path, and calculated width for, hash_key: ' + hash_key)
        return r
      end

      # no caching, use original Tempfile method.
      L('no caching.  writing to tempfile')
      r.temp_file_handle = Tempfile.new([PREFIX_STEM, '.svg'])
      r.svg_file_path = r.temp_file_handle.path
      self.class.tempfiles << r.temp_file_handle
      r.temp_file_handle.write(svg_output)
      r.temp_file_handle.close
      # no unlinking here.  unlink after the temp file has been used.

      L("returning uncached temp file path: #{r.svg_file_path}, and svg width: #{r.svg_width}")
      r
    end

    private

    def get_debug_level(node)
      return node.document.attributes[ATTRIBUTE_DEBUG].to_i unless node.document.attributes[ATTRIBUTE_DEBUG].nil?

      0
    end

    def L(debug_text)
      Asciidoctor::LoggerManager.logger.debug('PATCH: ' + debug_text)
    end

    def get_latex_from_node(node, is_inline)
      if is_inline
        node_arg1 = node.text
        node_arg2 = node.type
      else
        node_arg1 = node.content
        node_arg2 = node.style.to_sym
      end

      extract_latex_content(node_arg1, node_arg2)
    end

    def get_hash_key(latex_content, math_font_name, is_inline, debug_level)
      b = (is_inline ? 'true' : 'false')
      d = 'false'
      d = debug_level.to_s unless debug_level.nil?
      data = latex_content + math_font_name + b + d

      Digest::MD5.hexdigest(data).freeze
    end

    def get_user_scaling(node, is_inline)
      if is_inline
        if is_node_heading(node)
          if !node.document.attributes[ATTRIBUTE_INLINE_HEADING_SCALE].nil?
            node.document.attributes[ATTRIBUTE_INLINE_HEADING_SCALE].to_f
          else
            SCALE_INLINE_HEADING_DEFAULT
          end
        elsif !node.document.attributes[ATTRIBUTE_INLINE_BODY_SCALE].nil?
          node.document.attributes[ATTRIBUTE_INLINE_BODY_SCALE].to_f
        else
          SCALE_INLINE_BODY_DEFAULT
        end
      else
        unless node.document.attributes[ATTRIBUTE_BODY_SCALE].nil?
          return node.document.attributes[ATTRIBUTE_BODY_SCALE].to_f
        end

        SCALE_BODY_DEFAULT
      end
    end

    # Calculate width of final SVG image for display at the surrounding font height.
    def get_scaled_svg_width(node, font_size, viewbox_width, is_inline)
      L('viewbox width is: ' + viewbox_width.to_s)

      ex_width = viewbox_width / 500 # MathJax v4 approximate/generalized conversion.
      svg_point_width = ex_width * POINTS_PER_EX # scale to 1pt.
      node_text_ratio = font_size / REFERENCE_FONT_SIZE.to_f # scale to local font size.

      user_scaling = get_user_scaling(node, is_inline)

      w = svg_point_width * node_text_ratio * user_scaling
      L('Returning SCALED WIDTH: ' + w.to_s)

      w
    end

    def get_adjusted_svg_from_node(node, latex_content, is_inline)
      math_font_name = get_math_font_name

      svg_output, error = stem_to_svg(latex_content, math_font_name, is_inline)

      if svg_output == ''
        s = "No svg produced when adjusting LaTeX:\n" + latex_content
        Asciidoctor::LoggerManager.logger.error(s)
        error = s
      end

      return nil, error unless error.nil?

      svg_output = adjust_svg_color(svg_output, @font_color)

      svg_doc = REXML::Document.new(svg_output)
      root = svg_doc.root

      raise('No width found in SVG') if root.attributes['width'].nil?

      # Remove fuzzy outline
      root.attributes['shape-rendering'] = 'geometricPrecision'
      root.elements.delete_all('style')

      vb = root.attributes['viewBox'].split.map(&:to_f)
      v_x = vb[0]
      v_y = vb[1]
      v_width = vb[2]
      v_height = vb[3]

      # Add background if debug
      if get_debug_level(node) > 0
        L('DEBUG attribute set. Inserting svg background element to highlight svg image.')

        horizontal_line = REXML::Element.new('line')
        horizontal_line.add_attributes({
                                         'x1' => '0',
                                         'y1' => '0',
                                         'x2' => v_width,
                                         'y2' => '0',
                                         'stroke' => 'red',
                                         'stroke-width' => '50'
                                       })
        # root.add_element(horizontal_line)
        root.insert_before(root.elements[1], horizontal_line)

        bg = REXML::Element.new('rect')
        debug_color = node.document.attributes[ATTRIBUTE_DEBUG_COLOR] || 'beige'
        bg.add_attributes({
                            'x' => v_x,
                            'y' => v_y,
                            'width' => v_width,
                            'height' => v_height,
                            'fill' => debug_color,
                            'stroke' => 'black',
                            'stroke-width' => '10'
                          })

        # Insert as the FIRST child so it stays behind the math
        root.insert_before(root.elements[1], bg)

        updated_svg_output = ''
        svg_doc.write(updated_svg_output)
        svg_output = updated_svg_output
      end

      [svg_output: svg_output, svg_viewbox_width: v_width]
    end

    def get_adjusted_svg_and_set_cached_width(node, latex_content, is_inline, hash_key)
      adjusted_svg, error = get_adjusted_svg_from_node(node, latex_content, is_inline)

      return nil, error unless error.nil?

      @@cached_svg_viewbox_width[hash_key] = adjusted_svg[:svg_viewbox_width]

      adjusted_svg
    end

    # get_SVG_info starts down the cached path if this is not nil.
    def get_cache_dir(node)
      (node.document.attributes[ATTRIBUTE_CACHE_DIR] || nil).freeze
    end

    def get_cached_svg_file_path(cache_dir, hash_key)
      File.join(cache_dir, PREFIX_STEM + hash_key + '.svg')
    end

    def get_cached_svg_width_path(cache_dir, hash_key)
      File.join(cache_dir, PREFIX_WIDTH + hash_key)
    end

    def get_cached_svg_viewbox_width(cache_dir, hash_key)
      unless @@cached_svg_viewbox_width[hash_key] # Not cached; Read from file.
        file_name = get_cached_svg_width_path(cache_dir, hash_key)
        svg_viewbox_width = File.read(file_name).to_f
        L('Viewbox WIDTH loaded from DISK to ram for hash_key: ' + hash_key)
        @@cached_svg_viewbox_width[hash_key] = svg_viewbox_width.freeze
      end

      svg_viewbox_width = @@cached_svg_viewbox_width[hash_key]
      L('Returning viewbox WIDTH: ' + svg_viewbox_width.to_s + ' from RAM for hash_key: ' + hash_key)
      svg_viewbox_width
    end

    def get_math_font_name
      # TODO: MathJax v4 is more difficult to configure.

      # node.document.attributes[ATTRIBUTE_FONT] || MATHJAX_DEFAULT_FONT_FAMILY
      MATHJAX_DEFAULT_FONT_FAMILY
    end

    def is_node_heading(node)
      return false if node.nil?

      return true if node.parent.context == :section || node.parent.is_a?(Asciidoctor::Section)

      # Use &. to safely check context even if parent is nil
      return true if node.parent.context == :section
      return true if node.parent.is_a?(Asciidoctor::Section)
      return true if node.is_a?(Asciidoctor::Section)

      # Check if the node is the title of its parent safely
      return true if node.parent&.respond_to?(:title) && (node.parent.title == node.to_s)

      false
    end

    def extract_latex_content(content, type)
      content = content.strip.gsub('&amp;', '&').gsub('&lt;', '<').gsub('&gt;', '>')
      case type
      when :latexmath
        content
      when :asciimath
        AsciiMath.parse(content).to_latex
      end
    end

    def adjust_svg_color(svg_output, font_color)
      svg_output.gsub(MATHJAX_DEFAULT_COLOR_STRING, "##{font_color}")
    end

    def stem_to_svg(latex_content, math_font_name, is_inline)
      js_script = File.join(File.dirname(__FILE__), '../bin/render.js')
      svg_output = nil
      error = nil
      format = is_inline ? 'inline' : 'block'
      begin
        Open3.popen3('node', js_script, latex_content, format, POINTS_PER_EX.to_s,
                     math_font_name) do |_, stdout, _stderr, _wait_thr|
          svg_output = stdout.read
        end
      rescue Errno::ENOENT => e
        error = "Node.js executable 'node' was not found. Please install Node.js and ensure 'node' is available on your PATH. Original error: #{e.message}"
        svg_output = nil
      end

      L('stem to svg error: ' + error) if error

      # remove any outlines -- looks grainy/aliased/pixilated
      svg_output.gsub!(/stroke=["'][^"']+["']/, 'stroke="none"')
      svg_output.gsub!(/stroke-width=["'][^"']+["']/, 'stroke-width="0"')

      [svg_output, error]
    end

    def get_font_from_context(node)
      theme = node.document.converter.instance_variable_get(:@theme)

      if theme.nil?
        return {
          font_family: FALLBACK_FONT_FAMILY,
          font_style: FALLBACK_FONT_STYLE,
          font_size: FALLBACK_FONT_SIZE,
          font_color: FALLBACK_FONT_COLOR
        }
      end

      node_context = find_font_context(node)
      Asciidoctor::LoggerManager.logger.debug "Found font context #{node_context} for node #{node}"

      if node_context.is_a?(Asciidoctor::Section)
        level = node_context.level.next
        theme_key = "heading_h#{level}"
        theme_key = 'abstract_title' if node_context.sectname == 'abstract'

        font_family = theme["#{theme_key}_font_family"] || theme['heading_font_family'] || theme['base_font_family'] || FALLBACK_FONT_FAMILY
        font_style = theme["#{theme_key}_font_style"] || theme['heading_font_style'] || theme['base_font_style'] || FALLBACK_FONT_STYLE
        font_size = theme["#{theme_key}_font_size"] || theme['heading_font_size'] || theme['base_font_size'] || FALLBACK_FONT_SIZE
        font_color = theme["#{theme_key}_font_color"] || theme['heading_font_color'] || theme['base_font_color'] || FALLBACK_FONT_COLOR
      elsif node_context
        theme_key = if node_context.parent.is_a?(Asciidoctor::Section) && node_context.parent.sectname == 'abstract'
                      :abstract
                    else
                      :base
                    end

        font_family = nil
        font_style = nil
        font_size = nil
        font_color = nil
        converter = node_context.converter
        converter&.theme_font theme_key do
          font_family = converter.font_family || FALLBACK_FONT_FAMILY
          font_style = converter.font_style || FALLBACK_FONT_STYLE
          font_size = converter.font_size || FALLBACK_FONT_SIZE
          font_color = converter.font_color || FALLBACK_FONT_COLOR
        end
      else
        raise "No font context found for node #{node}"
      end

      { font_family: font_family, font_style: font_style, font_size: font_size, font_color: font_color }
    end

    def find_font_context(node)
      while node
        return node unless node.is_a?(Asciidoctor::Inline)

        node = node.parent
      end
      node
    end
  end

  SERVICE = MathjaxService.new

  # Tree processors handle block level nodes.
  class BlockProcessor < Asciidoctor::Extensions::Treeprocessor
    def process(document)
      (document.find_by context: :stem).each do |node|
        next unless node.style == 'latexmath'

        svg_result, error = SERVICE.get_svg_info(node, false)

        Asciidoctor::LoggerManager.logger.error(error) if error

        # L('Attempting to insert BLOCK SVG.')

        # 1. Guard against nil path before creating the block
        next unless svg_result && svg_result.svg_file_path

        attrs = {
          'target' => svg_result.svg_file_path,
          'align' => 'center',
          'pdfwidth' => svg_result.svg_width.to_s,
          'alt' => svg_result.latex_content,
          'format' => 'svg'
        }

        # The attributes must be nested INSIDE the options hash under the 'attributes' key
        options = {
          'content_model' => :empty,
          'attributes' => attrs,
          :attributes => attrs
        }

        # Now call new with exactly 3 arguments: parent, context, options
        image_block = Asciidoctor::Block.new(node.parent, :image, options)

        parent = node.parent
        idx = parent.blocks.index(node)
        parent.blocks[idx] = image_block

        svg_result.temp_file_handle.unlink unless svg_result.temp_file_handle.nil?
      end
    end
  end

  Asciidoctor::Extensions.register do
    # This tells Asciidoctor to use your Treeprocessor class
    treeprocessor BlockProcessor
  end

  # Converters are low-level, however, better-handle inline stem than tree processors.
  class InlineProcessor < (Asciidoctor::Converter.for 'pdf')
    register_for 'pdf'

    def convert_inline_quoted(node)
      svg_result, error = SERVICE.get_svg_info(node, true)

      if error
        Asciidoctor::LoggerManager.logger.error(error)
        return super
      end

      return super if svg_result.latex_content == ''

      begin
        # L('Attempting to insert INLINE SVG.')
        if error.nil?
          Asciidoctor::LoggerManager.logger.debug "Successfully embedded stem inline #{node.text} with font #{svg_result.svg_font_name} as SVG image"
          quoted_text = "<img src=\"#{svg_result.svg_file_path}\" format=\"svg\" width=\"#{svg_result.svg_width}\" alt=\"#{node.text}\">"
          node.id ? %(<a id="#{node.id}">#{DummyText}</a>#{quoted_text}) : quoted_text
        end
      rescue StandardError => e
        Asciidoctor::LoggerManager.logger.warn "Failed to process SVG: #{e.message}"
        super
      end
    end
  end
end

puts("\n")
puts('-- PATCHED with caching version of AsciiDoctor-PDF-MathJax extension loaded --')
puts("\n")
puts('To enable caching either: a) Add to your .adoc file header the attribute :' + ATTRIBUTE_CACHE_DIR + ': <Your Cache Directory>')
puts('Or, b) Add to the AsciiDoctor-PDF command line: -a ' + ATTRIBUTE_CACHE_DIR + '=<Your Cache Directory>')
puts('The first build of a file will take the longest because the cache is empty.  Subsequent builds will be significantly faster.')
puts("\n")
$stdout.flush
