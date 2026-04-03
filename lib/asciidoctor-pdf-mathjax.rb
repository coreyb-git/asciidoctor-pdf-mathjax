# FIXME: Level 0 headings need a different, or no, prefix.  Tall SVG's push Title headings away from the top of the document (no margin?)

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
FALLBACK_FONT_STYLE = 'normal'.freeze
FALLBACK_FONT_FAMILY = 'Arial'.freeze
FALLBACK_FONT_COLOR = '#000000'.freeze

POINTS_PER_EX = 6
REFERENCE_FONT_SIZE = 12

DEFAULT_FONT_SIZE = 12

MATHJAX_DEFAULT_COLOR_STRING = 'currentColor'.freeze
MATHJAX_DEFAULT_FONT_FAMILY = 'mathjax-newcm'.freeze

ATTRIBUTE_FONT = 'math-font'.freeze
# ATTRIBUTE_CACHE_DIR = 'math-cache-dir'.freeze
ATTRIBUTE_CACHE_DIR = 'imagesoutdir'.freeze # typical asciidoc image generation output path
ATTRIBUTE_IMAGES_DIR = 'imagesdir'.freeze # typical asciidoc image generation output path

ATTRIBUTE_USE_LITERAL_PATH = 'math-use-literal-path'.freeze

PREFIX_STEM = 'cached-stem-'.freeze
PREFIX_WIDTH = 'cached-stem-width-'.freeze # viewbox width cache files

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
  Result_struct = Struct.new(:latex_content, :svg_font_name, :svg_width_em, :svg_width_ex, :svg_width_pt, :svg_shortfilename,
                             :svg_file_path)

  class MathjaxService
    @@cached_svg_viewbox_width = {}
    @@cache_dir_init_done = false

    def get_svg_info(node, is_inline)
      r = Result_struct.new('', '', '', '', '', '', '')

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
        norm_prefix_hidden = "\\vphantom{#{norm_prefix_visible}}"
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

        r.svg_shortfilename = get_short_filename(node, hash_key)
        r.svg_file_path = get_cached_svg_file_path(cache_dir, hash_key)

        if File.exist?(r.svg_file_path)
          viewbox_width = get_cached_svg_viewbox_width(cache_dir, hash_key)
          scaled_width = get_scaled_svg_width(node, font_data[:font_size], viewbox_width, is_inline)
          r.svg_width_em = get_em_from_viewbox_width(scaled_width)
          r.svg_width_ex = get_ex_from_viewbox_width(scaled_width)
          r.svg_width_pt = get_pt_from_viewbox_width(scaled_width, font_data[:font_size])
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
      scaled_width = get_scaled_svg_width(node, font_data[:font_size], viewbox_width, is_inline)
      r.svg_width_em = get_em_from_viewbox_width(scaled_width)
      r.svg_width_ex = get_ex_from_viewbox_width(scaled_width)
      r.svg_width_pt = get_pt_from_viewbox_width(scaled_width, font_data[:font_size])

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
      temp_handle = Tempfile.new([PREFIX_STEM, '.svg'])
      r.svg_file_path = temp_handle.path
      temp_handle.write(svg_output)

      # no unlinking here.  unlink after the temp file has been used.
      # Get the existing array or an empty one
      handles = node.document.attr('math_tempfiles_handles') || []
      # Add the new handle
      handles << temp_handle
      # Save it back formally
      node.document.set_attr('math_tempfiles_handles', handles)

      temp_handle.close

      L("returning uncached temp file path: #{r.svg_file_path}")

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
        # node_arg1 = node.text
        # node_arg2 = node.type

        # If the node is a Block (Paragraph/List), it won't have .text
        # We check if it responds to .text (Inline) otherwise use the passed text
        node_arg1 = node.respond_to?(:text) ? node.text : node.to_s
        node_arg2 = node.respond_to?(:type) ? node.type : :latexmath # Default to latex
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

    def get_em_from_viewbox_width(width)
      width / 1000
    end

    def get_ex_from_viewbox_width(width)
      width / 500.0 # MathJax v4 approximate/generalized conversion.
    end

    def get_pt_from_viewbox_width(width, font_size)
      ex_width = get_ex_from_viewbox_width(width)

      svg_point_width = ex_width * POINTS_PER_EX # scale to 1pt.
      node_text_ratio = font_size / REFERENCE_FONT_SIZE.to_f # scale to local font size.

      svg_point_width * node_text_ratio
    end

    # Calculate width of final SVG image node for display at the surrounding font height.
    def get_scaled_svg_width(node, _font_size, viewbox_width, is_inline)
      viewbox_width * get_user_scaling(node, is_inline)
    end

    # clears the style element, and inserts debug elements when debugging.
    # adjusts internal svg width and height values.
    def get_adjusted_svg_from_node(node, latex_content, is_inline)
      math_font_name = get_math_font_name

      svg_output, error = stem_to_svg(latex_content, math_font_name, is_inline)

      if svg_output.nil?
        s = "No svg produced when adjusting LaTeX:\n" + latex_content
        Asciidoctor::LoggerManager.logger.error(s)
        error = s
      end

      return nil, error unless error.nil?

      # Fetch the color from the node, the document, or a hardcoded fallback
      #      node_font_colour = node.attr('fontcolor') || node.document.attr('fontcolor') || FALLBACK_FONT_COLOR

      # leave as currentColor.  This seems to be a legacy fix that isn't needed?  PDF's are printing to black
      # regardless.
      # svg_output = adjust_svg_color(svg_output, node_font_colour)

      svg_doc = REXML::Document.new(svg_output)
      root = svg_doc.root

      raise('No width found in SVG') if root.attributes['width'].nil?

      # Remove fuzzy outline
      root.attributes['shape-rendering'] = 'geometricPrecision'
      root.elements.delete_all('style')

      # Change ex to em so that web/kindle respects device font size being changed.
      # root_em_width = get_em_from_ex(root.attributes['width'].to_f)
      # root_em_height = get_em_from_ex(root.attributes['height'].to_f)
      # root.attributes['width'] = "#{root_em_width}em"
      # root.attributes['height'] = "#{root_em_height}em"

      if root.attributes['style'] =~ /vertical-align:\s*([\d.-]+)ex/
        # Convert to em so the WHOLE file is ex-free
        (::Regexp.last_match(1).to_f * 0.5).round(3)
        #        root.attributes['style'] = "vertical-align: #{v_align_em}em;"
      end

      # 1. Calculate the aspect ratio from the viewBox
      vb = root.attributes['viewBox'].split.map(&:to_f)
      v_x = vb[0]
      v_y = vb[1]
      v_width = vb[2]
      v_height = vb[3]

      #  root.attributes['width'] = v_width # "#{(v_width / 500).round(3)}ex"
      #     root.attributes['height'] = v_height # "#{(v_height / 500).round(3)}ex"
      #     root.attributes.delete('width')
      #     root.attributes.delete('height')
      root.attributes['preserveAspectRatio'] = 'xMinYMin meet'

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
      end

      updated_svg_output = ''
      svg_doc.write(updated_svg_output)
      svg_output = updated_svg_output

      [{ svg_output: svg_output, svg_viewbox_width: v_width }]
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

    # prefix the filename with the :imagesdir: value
    def get_short_filename(node, hash_key)
      imagesdir = './'
      name = "#{imagesdir}#{PREFIX_STEM}#{hash_key}.svg"
      if node.document.attributes[ATTRIBUTE_USE_LITERAL_PATH]
        name = get_cached_svg_file_path(get_cache_dir(node), hash_key)
      end

      name
    end

    def get_cached_svg_file_path(cache_dir, hash_key)
      File.join(cache_dir, "#{PREFIX_STEM}#{hash_key}.svg")
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

    # unused... unneeded legacy code?
    def adjust_svg_color(svg_output, font_color)
      # 1. Handle nil or empty inputs using the fallback
      # In Ruby, it's cleaner to check .nil? or .empty?
      target_color = font_color.nil? || font_color.empty? ? FALLBACK_FONT_COLOR : font_color

      # 2. Normalize the hex (strip the hash if it exists)
      clean_hex = target_color.to_s.delete('#')

      # 3. Perform the substitution
      # We add the '#' back here to ensure the SVG attribute is valid
      # Note: we return the result of gsub
      svg_output.gsub(MATHJAX_DEFAULT_COLOR_STRING, "##{clean_hex}")
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

      error = 'SVG is blank for LaTeX: ' + latex_content if svg_output == ''
      error = 'SVG output is nil for LaTeX: ' + latex_content if svg_output.nil?

      L('stem to svg error: ' + error) unless error.nil?

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

  class MathematicalTreeprocessor < Asciidoctor::Extensions::Treeprocessor
    LineFeed = %(\n)
    StemInlineMacroRx = /\\?(stem|(?:latex|ascii)math):([a-z,]*)\[(.*?[^\\])\]/m

    def process(document)
      return unless document.attr? 'stem'

      (document.find_by context: :stem, traverse_documents: true).each do |stem|
        handle_stem_block stem
      end

      document.find_by(traverse_documents: true) do |b|
        (b.content_model == :simple && (b.subs.include? :macros)) || b.context == :list_item
      end.each do |prose|
        handle_prose_block prose
      end

      (document.find_by content: :section).each do |sect|
        handle_section_title sect
      end

      document.remove_attr 'stem'
      begin
        (document.instance_variable_get :@header_attributes).delete 'stem'
      rescue StandardError
        nil
      end

      nil
    end

    def get_dpi_adjusted(width_pt)
      # dpi_target = 150
      dpi_target = 90
      dpi_base = 90
      ((width_pt * dpi_target) / dpi_base).round(3)
    end

    def handle_stem_block(stem)
      equation_type = stem.style.to_sym

      case equation_type
      when :latexmath
        content = stem.content
      when :asciimath
        content = AsciiMath.parse(stem.content).to_latex
      else
        return
      end

      svg_result, = SERVICE.get_svg_info(stem, false)

      img_target = svg_result.svg_shortfilename
      svg_result.svg_width_em
      img_width_pt = svg_result.svg_width_pt
      dpi_adjusted_pt = get_dpi_adjusted(img_width_pt)

      alt_text = stem.attr 'alt', (equation_type == :latexmath ? %($$#{content}$$) : %(`#{content}`))
      # alt_text = ''

      attrs = {
        'target' => img_target,
        'alt' => alt_text,
        'align' => 'center',
        'width' => "#{dpi_adjusted_pt}pt", # For HTML/General
        'pdfwidth' => "#{img_width_pt}pt", # FORCE the specific size in the PDF
        'format' => 'svg'
      }

      parent = stem.parent
      stem_image = create_image_block parent, attrs
      stem_image.id = stem.id if stem.id
      if (title = stem.attributes['title'])
        stem_image.title = title
      end
      parent.blocks[parent.blocks.index stem] = stem_image
    end

    def handle_prose_block(prose)
      if %i[list_item table_cell].include?(prose.context)
        use_text_property = true
        text = prose.instance_variable_get :@text
      else
        text = prose.lines * LineFeed
      end
      text, source_modified = handle_inline_stem(prose, text)

      return unless source_modified

      if use_text_property
        prose.text = text
      else
        prose.lines = text.split LineFeed
      end
    end

    def handle_section_title(sect)
      text = sect.instance_variable_get :@title
      text, source_modified = handle_inline_stem sect, text
      sect.title = text if source_modified
    end

    def handle_inline_stem(node, text)
      document = node.document
      source_modified = false

      return [text, source_modified] unless document.attr? 'stem'

      to_html = document.basebackend? 'html'

      default_equation_type = document.attr('stem').include?('tex') ? :latexmath : :asciimath

      # TODO: skip passthroughs in the source (e.g., +stem:[x^2]+)
      if text && text.include?(':') && (text.include?('stem:') || text.include?('math:'))
        text = text.gsub(StemInlineMacroRx) do
          if (m = $~)[0].start_with? '\\'
            next m[0][1..-1]
          end

          next '' if (eq_data = m[3].rstrip).empty?

          eq_data = eq_data.gsub('\]', ']')
          subs = if m[2].nil_or_empty?
                   to_html ? [:specialcharacters] : []
                 else
                   (node.resolve_pass_subs m[2])
                 end
          eq_data = node.apply_subs eq_data, subs unless subs.empty?
          eq_type = (m[1] == 'stem' ? default_equation_type : m[1].to_sym)

          # --- CREATE THE GHOST NODE ---
          # We create a temporary Inline node that holds ONLY the captured math.
          # This keeps your SERVICE happy but limits the scope to the equation.
          ghost_node = Asciidoctor::Inline.new(node, :quoted, eq_data, type: eq_type)

          # Inside your gsub loop in handle_inline_stem
          svg_result, error = SERVICE.get_svg_info(ghost_node, true)

          if error
            Asciidoctor::LoggerManager.logger.error("Math Error: #{error}")
            next m[0] # Return original text if it fails
          end

          source_modified = true

          # 1. FORCE REGISTRATION
          doc = node.document
          if doc.respond_to?(:references)
            # Ensure the images key is an array before pushing to it
            doc.references[:images] ||= []
            unless doc.references[:images].include?(svg_result.svg_file_path)
              doc.references[:images] << svg_result.svg_file_path
            end
          end

          # 2. BACKEND SPECIFIC LOGIC
          is_epub = doc.basebackend? 'epub3'

          # CRITICAL FIX: The EPUB converter crashes if 'node' doesn't have a stable
          # chain up to a chapter. If node.parent is nil, or it's a heading/title,
          # we MUST use the passthrough to bypass the internal Ruby registration.
          use_passthrough = is_epub && (node.parent.nil? || %i[document section preamble].include?(node.context))

          #           if use_passthrough
          #             # Bypass the crashing 'register_media_file' by using raw HTML
          #             %(pass:[<img src="#{svg_result.svg_shortfilename}" style="vertical-align: middle;" />])
          #           else
          #             # Standard macro for PDF and regular prose blocks
          #             %(image:#{svg_result.svg_shortfilename}[pdfwidth=#{img_width_ex}ex])
          #           end

          alt_text = ''

          svg_result.svg_width_em
          img_width_pt = svg_result.svg_width_pt

          dpi_adjusted_pt = get_dpi_adjusted(img_width_pt)

          # CAN'T USE AUTO as kindle previewer crashes.
          if use_passthrough
            # Bypass the crashing 'register_media_file' by using raw HTML
            %(pass:[<img src="#{svg_result.svg_shortfilename}" width="#{dpi_adjusted_pt}pt" style="vertical-align: middle;" />])
          else
            # Standard macro for PDF and regular prose blocks
            # THIS ALSO IS FOR INLINE EPUB.
            # It seems that only width and alt survive and pdfwidth survive, and other attributes are stripped by
            # asciidoctor-epub3
            # setting width to point seems to scale for inline blocks on kindle online previewer.
            #   %(image:#{svg_result.svg_shortfilename}[pdfwidth=#{img_width_pt}pt, width=#{dpi_adjusted_pt}pt, alt="#{alt_text}"])
            %(image:#{svg_result.svg_shortfilename}[pdfwidth=#{img_width_pt}pt, width=#{dpi_adjusted_pt}pt, alt="#{alt_text}"])
          end
        end
      end

      [text, source_modified]
    end
  end

  Asciidoctor::Extensions.register do
    treeprocessor MathjaxToSVGExtension::MathematicalTreeprocessor
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
