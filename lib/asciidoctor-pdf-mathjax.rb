require 'asciidoctor-pdf' unless Asciidoctor::Converter.for 'pdf'
require 'open3'
require 'tempfile'
require 'rexml/document'
require 'ttfunk'
require 'asciimath'

require 'digest'

POINTS_PER_EX = 6
REFERENCE_FONT_SIZE = 12

MATHJAX_DEFAULT_COLOR_STRING = 'currentColor'
MATHJAX_DEFAULT_FONT_FAMILY = 'mathjax-newcm'

ATTRIBUTE_FONT = 'math-font'
ATTRIBUTE_CACHE_DIR = 'math-cache-dir'

PREFIX_STEM = 'stem-'
PREFIX_WIDTH = 'width-' # width cache files

##### Normalize the height of the SVG image. #####
# Prawn vertically centers the resulting SVG image.
# This means that vertically imbalanced SVG's will appear to drift up or down
# in their vertical alignment compared to surrounding text.
# \vphantom is a LaTeX zero-width invisible glyph.
# MathJax will only go 2 levels deep in superscripts and subscripts,
# thus the following text produces the tallest, vertically centered, output SVG.
# However, capital letter vectors break this, and are slightly taller,
# with extra padding above the vector arrow.  This causes vertical misalignment.
# Removing that padding re-aligns everything.
# #### CAUTION:
# This will shave the bottom of an integral if it has a super and sub scripts.
# VPHANTOM_BASE = 'H_{H_H}I^{I^I}'
VPHANTOM_BASE = 'H_{H_H} I^{I^I}'
VPHANTOM_LATEX = '\vphantom{' + VPHANTOM_BASE + '}'
#####

ATTRIBUTE_DEBUG = 'math-debug'
ATTRIBUTE_DEBUG_COLOR = 'math-debug-color'
ATTRIBUTE_INLINE_BODY_SCALE = 'math-inline-body-scale'
ATTRIBUTE_INLINE_HEADING_SCALE = 'math-inline-heading-scale'
SCALE_INLINE_HEADING_DEFAULT = 1.0
SCALE_INLINE_BODY_DEFAULT = 1.0

class AsciiDoctorPDFMathjax < (Asciidoctor::Converter.for 'pdf')
  register_for 'pdf'

  @tempfiles = []
  class << self
    attr_reader :tempfiles
  end

  @@cached_svg_viewbox_width = {}
  @@cache_dir_init_done = false

  # Proportions of viewbox y values above and below y=0
  @@calibrated_svg_portion_neg = nil
  @@calibrated_svg_portion_pos = nil
  @@calibrated_svg_ratio_pos_per_min = nil
  @@calibrated_svg_ratio_neg_per_pos = nil

  def convert_stem(node)
    arrange_block node do |_|
      add_dest_for_block node if node.id

      svg_result, error = get_svg_info(node, false)

      logger.error(error) if error

      L('Attempting to insert BLOCK SVG.')

      # noinspection RubyResolve
      code_padding = @theme.code_padding
      if error
        # logger.warn "Failed to convert STEM to SVG: #{error} (Fallback to code block)"
        logger.warn 'Failed to convert STEM to SVG. (Fallback to code block)'
        pad_box code_padding, node do
          theme_font :code do
            typeset_formatted_text [{ text: (guard_indentation svg_result.latex_content), color: @font_color }],
                                   (calc_line_metrics @base_line_height),
                                   bottom_gutter: @bottom_gutters[-1][node]
          end
        end
      else
        # removed width and temp file code

        begin
          # removed temp file writing and close

          pad_box code_padding, node do
            image_obj = image svg_result.svg_file_path, position: :center, width: svg_result.svg_width, height: nil
            if image_obj
              logger.debug "Successfully embedded stem block (as latex) #{svg_result.latex_content} as SVG image"
            end
          rescue Prawn::Errors::UnsupportedImageType => e
            logger.warn "Unsupported image type error: #{e.message}"
          rescue StandardError => e
            logger.warn "Failed embedding SVG: #{e.message}"
          end
        ensure
          svg_result.temp_file_handle.unlink unless svg_result.temp_file_handle.nil?
        end
      end
    end
    theme_margin :block, :bottom, (next_enclosed_block node)
  end

  def convert_inline_quoted(node)
    svg_result, error = get_svg_info(node, true)

    if error
      logger.error(error)
      return super
    end

    return super if svg_result.latex_content == ''

    # removed svg temp file handle creation

    begin
      # removed writing of adjusted svg, and closing of handle

      L('Attempting to insert INLINE SVG.')
      if error.nil?
        logger.debug "Successfully embedded stem inline #{node.text} with font #{svg_result.svg_font_name} as SVG image"
        quoted_text = "<img src=\"#{svg_result.svg_file_path}\" format=\"svg\" width=\"#{svg_result.svg_width}\" alt=\"#{node.text}\">"
        node.id ? %(<a id="#{node.id}">#{DummyText}</a>#{quoted_text}) : quoted_text
      end
    rescue StandardError => e
      logger.warn "Failed to process SVG: #{e.message}"
      super
    end
  end

  private

  def is_debug(node)
    return true if node.document.attributes[ATTRIBUTE_DEBUG]

    false
  end

  def L(debug_text)
    logger.debug('PATCH: ' + debug_text)
  end

  def get_svg_info(node, is_inline)
    result_struct = Struct.new(:latex_content, :svg_font_name, :svg_width, :svg_file_path,
                               :temp_file_handle)
    r = result_struct.new('', '', '', '', nil)

    r.svg_font_name = get_math_font_name # part of final log when embedding into pdf

    temp_latex_content = get_latex_from_node(node, is_inline)

    return r, nil if temp_latex_content.nil?

    L("+++ Processing LaTeX: \n#{temp_latex_content}")

    if is_inline
      # Normalize inline SVG alignment of characters
      temp_inline = is_debug(node) ? VPHANTOM_BASE : VPHANTOM_LATEX
      temp_latex_content = temp_inline + temp_latex_content
    end

    r.latex_content = temp_latex_content

    hash_key = get_hash_key(r.latex_content, r.svg_font_name, is_inline)

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
        r.svg_width = get_scaled_svg_width(node, viewbox_width, is_inline)
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

    r.svg_width = get_scaled_svg_width(node, viewbox_width, is_inline)

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

  def get_hash_key(latex_content, math_font_name, is_inline)
    b = (is_inline ? 'true' : 'false')
    data = latex_content + math_font_name + b

    Digest::MD5.hexdigest(data).freeze
  end

  def get_user_scaling(node)
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
  end

  def init_calibrated_svg_viewbox_y_values
    return unless @@calibrated_svg_portion_neg.nil?

    L('CALIBRATION: Determining +- y value proportions in viewbox.')
    latex = VPHANTOM_LATEX + '\text{calibration}'
    font_name = get_math_font_name
    svg_output, = stem_to_svg(latex, font_name, true)

    svg_doc = REXML::Document.new(svg_output)

    vb = svg_doc.root.attributes['viewBox'].split.map(&:to_f)
    vb_y = vb[1] # starting y value.  MathJax starts at a negative y value.
    vb_height = vb[3]

    portion_pos = vb_height - vb_y.abs
    portion_neg = vb_y.abs

    @@calibrated_svg_portion_neg = portion_neg
    @@calibrated_svg_portion_pos = portion_pos

    @@calibrated_svg_ratio_pos_per_min = portion_pos / portion_neg
    @@calibrated_svg_ratio_neg_per_pos = portion_neg / portion_pos

    L("CALIBRATION: Normalized viewbox proprotions, pos/neg: #{@@calibrated_svg_ratio_pos_per_min}, neg/pos: #{@@calibrated_svg_ratio_neg_per_pos}")
  end

  # Calculate width of final SVG image for display at the surrounding font height.
  def get_scaled_svg_width(node, viewbox_width, is_inline)
    L('viewbox width is: ' + viewbox_width.to_s)

    ex_width = viewbox_width / 500 # MathJax v4 approximate/generalized conversion.
    svg_point_width = ex_width * POINTS_PER_EX # scale to 1pt.
    node_text_ratio = get_node_font_size_s(node, is_inline).to_f / REFERENCE_FONT_SIZE # scale to local font size.

    user_scaling = get_user_scaling(node)

    w = svg_point_width * node_text_ratio * user_scaling
    L('Returning SCALED WIDTH: ' + w.to_s)

    w
  end

  def get_adjusted_svg_from_node(node, latex_content, is_inline)
    math_font_name = get_math_font_name

    svg_output, error = stem_to_svg(latex_content, math_font_name, is_inline)

    if svg_output == ''
      s = "No svg produced when adjusting LaTeX:\n" + latex_content
      logger.error(s)
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

    if is_inline
      ##### Correct any abnormally tall viewbox's and normalize the height.
      init_calibrated_svg_viewbox_y_values

      portion_pos = v_height - v_y.abs
      portion_neg = v_y.abs

      # If the negative portion is larger than normal then expand
      # the positive portion, if it's too small, to re-center image.
      if portion_neg > @@calibrated_svg_portion_neg
        L('-- Viewbox Negative portion is larger than normal')
        pos_per_neg = portion_pos / portion_neg
        if pos_per_neg < @@calibrated_svg_ratio_pos_per_min
          L("Adjusting + section of viewbox. Before: #{portion_pos}, height: #{v_height}")
          portion_pos = portion_neg * @@calibrated_svg_ratio_pos_per_min
          v_height = portion_neg + portion_pos
          L("Portion after: #{portion_pos}, height: #{v_height}")
        end

      end

      # If the positive portion is larger, adjust negative portion.
      if portion_pos > @@calibrated_svg_portion_pos
        neg_per_pos = portion_neg / portion_pos
        if neg_per_pos < @@calibrated_svg_ratio_neg_per_pos
          L("-- Adjusting negative section of viewbox. Portion before: #{portion_neg}, start y: #{v_y}")
          v_y = 0 - (portion_pos * @@calibrated_svg_ratio_neg_per_pos)
          portion_neg = v_y.abs
          v_height = portion_pos + portion_neg
          L("Portion after: #{portion_neg}, start y: #{v_y}")
        end
      end

      # Adjust SVG height

      # overwrite existing values
      root.add_attributes({
                            'width' => "#{v_width}ex",
                            'height' => "#{v_height}ex"
                          })

      # Vertically center
      root.add_attributes({ 'style' => 'vertical-align: 0.0ex' })

      # Rewrite the xml with the new viewBox and height values.

      svg_doc.root.attributes['viewBox'] = "#{v_x} #{v_y} #{v_width} #{v_height}"
      updated_svg_output = ''
      svg_doc.write(updated_svg_output)
      svg_output = updated_svg_output
    end

    # 'none' tells the browser/renderer: "Do not maintain the aspect ratio.
    # Stretch to fit the container exactly."

    # Add background if debug
    if is_debug(node)
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
      root.add_element(horizontal_line)

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

      bg.add_attributes({
                          'x' => v_x,
                          'y' => v_y * 100,
                          'width' => v_width,
                          'height' => v_height * 10_000,
                          'fill' => debug_color,
                          'stroke' => 'black',
                          'stroke-width' => '10'
                        })
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
    return true if node.parent.context == :section || node.parent.is_a?(Asciidoctor::Section)

    false
  end

  def get_node_font_size_s(node, is_inline)
    theme = (load_theme node.document)

    if is_inline && is_node_heading(node)
      level = node.parent.level + 1
      # Try to get the specific size for this heading level (h1, h2, etc.)
      heading_size = theme["heading_h#{level}_font_size"] || theme.heading_font_size
      return heading_size.to_s if heading_size
    end

    # Body text
    if theme && theme.respond_to?(:base_font_size)
      theme.base_font_size.to_s
    elsif node.document.attr('pdf-page-font-size')
      node.document.attr('pdf-page-font-size')
    elsif node.document.attr('font-size')
      node.document.attr('font-size')
    else
      # Default size
      '12'
    end
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
end

puts("\n")
puts('-- PATCHED with caching version of AsciiDoctor-PDF-MathJax extension loaded --')
puts("\n")
puts('To enable caching either: a) Add to your .adoc file header the attribute :' + ATTRIBUTE_CACHE_DIR + ': <Your Cache Directory>')
puts('Or, b) Add to the AsciiDoctor-PDF command line: -a ' + ATTRIBUTE_CACHE_DIR + '=<Your Cache Directory>')
puts('The first build of a file will take the longest because the cache is empty.  Subsequent builds will be significantly faster."')
puts("\n")
$stdout.flush
