require 'asciidoctor-pdf' unless Asciidoctor::Converter.for 'pdf'
require 'open3'
require 'tempfile'
require 'rexml/document'
require 'ttfunk'
require 'asciimath'

require 'digest'

POINTS_PER_EX = 6
MATHJAX_DEFAULT_COLOR_STRING = 'currentColor'
MATHJAX_DEFAULT_FONT_FAMILY = 'mathjax-newcm'

FALLBACK_FONT_SIZE = 12
FALLBACK_FONT_STYLE = 'normal'
FALLBACK_FONT_FAMILY = 'Arial'
FALLBACK_FONT_COLOR = '#000000'

ATTRIBUTE_FONT = 'math-font'
ATTRIBUTE_CACHE_DIR = 'math-cache-dir'
PREFIX_STEM = 'stem-'
PREFIX_WIDTH = 'width-' # width cache files

# PHANTOM_LATEX = '\vphantom{\int^A}\vphantom{\int_y}'.freeze

PHANTOM_INLINE_BODY_LATEX = '\text{Zdf}'
PHANTOM_INLINE_HEADING_LATEX = '\text{Zdf}'

SCALE_INLINE_HEADING_DEFAULT = 0.55
SCALE_INLINE_BODY_DEFAULT = 0.85

class AsciiDoctorPDFMathjax < (Asciidoctor::Converter.for 'pdf')
  register_for 'pdf'

  @tempfiles = []
  class << self
    attr_reader :tempfiles
  end

  @@cached_svg_width = {}
  @@cached_svg_output = {}
  @@cache_dir_init_done = false

  def convert_stem(node)
    arrange_block node do |_|
      add_dest_for_block node if node.id

      svg_result, error = get_svg_info(node, false)

      logger.error(error) if error

      # noinspection RubyResolve
      code_padding = @theme.code_padding
      if svg_result.svg_output == ''
        # logger.warn "Failed to convert STEM to SVG: #{error} (Fallback to code block)"
        logger.warn 'Failed to convert STEM to SVG. (Fallback to code block)'
        pad_box code_padding, node do
          theme_font :code do
            typeset_formatted_text [{ text: (guard_indentation latex_content), color: @font_color }],
                                   (calc_line_metrics @base_line_height),
                                   bottom_gutter: @bottom_gutters[-1][node]
          end
        end
      else
        # removed width and temp file code

        begin
          # removed temp file writing and close

          # L('Prawn embed path: ' + file_path)
          # L('Prawn embed width:' + svg_width.to_s)

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

    if svg_result.svg_output == ''
      logger.warn "Error processing stem: #{error || 'No SVG output'}"
      return super
    end

    # removed svg temp file handle creation

    begin
      # removed writing of adjusted svg, and closing of handle

      # math_font = get_math_font_name(node).freeze

      if error.nil?
        logger.debug "Successfully embedded stem inline #{node.text} with font #{svg_result.font_name} as SVG image"
        quoted_text = "<img src=\"#{svg_result.svg_file_path}\" format=\"svg\" width=\"#{svg_result.svg_width}\" alt=\"#{node.text}\">"
        node.id ? %(<a id="#{node.id}">#{DummyText}</a>#{quoted_text}) : quoted_text
      end
    rescue StandardError => e
      logger.warn "Failed to process SVG: #{e.message}"
      super
    end
  end

  protected

  def L(debug_text)
    logger.debug('PATCH: ' + debug_text)
  end

  # return {file_path, svg_width, temp_handle, inline_nil_latex, inline_nil_svg}
  def get_svg_info(node, is_inline)
    result_struct = Struct.new(:latex_content, :svg_output, :svg_width, :font_name, :font_size, :svg_file_path,
                               :temp_file_handle)
    r = result_struct.new('', '', '', '', '', '', nil)

    if is_inline
      node_arg1 = node.text
      node_arg2 = node.type
    else
      node_arg1 = node.content
      node_arg2 = node.style.to_sym
    end
    temp_latex_content = extract_latex_content(node_arg1, node_arg2)

    return r, nil if temp_latex_content.nil?

    is_heading = is_node_heading(node)

    if is_inline
      # Normalize inline SVG alignment of characters
      temp_latex_content = if is_heading
                             PHANTOM_INLINE_HEADING_LATEX + temp_latex_content
                           else
                             PHANTOM_INLINE_BODY_LATEX + temp_latex_content
                           end
    end

    r.latex_content = temp_latex_content

    r.font_name = get_math_font_name(node)
    r.font_size = get_node_font_size_s(node, is_inline)

    hash_key = get_hash_key(temp_latex_content, r.font_name, r.font_size, is_inline)

    cache_dir = (node.document.attributes[ATTRIBUTE_CACHE_DIR] || nil).freeze
    unless cache_dir.nil? # caching enabled
      unless @@cache_dir_init_done # ensure directory exists
        L('INIT cache dir: ' + cache_dir)
        @@cache_dir_init_done = true
        FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)
      end

      r.svg_file_path = get_cached_svg_file_path(cache_dir, hash_key)

      unless @@cached_svg_output[hash_key].nil? # read from memory
        r.svg_width = get_cached_svg_width(cache_dir, hash_key)
        r.svg_output = get_cached_svg_output(cache_dir, hash_key)
        return r
      end

      if File.exist?(r.svg_file_path)
        r.svg_width = get_cached_svg_width(cache_dir, hash_key)
        r.svg_output = get_cached_svg_output(cache_dir, hash_key)
        return r
      end
    end

    # caching disabled, or file doesn't exist in cache yet, so create
    L('GENERATING data for hash_key:' + hash_key + ' -- Latex content: ' + r.latex_content)

    adjusted_svg, error = get_adjusted_svg_and_set_cached_width(r.latex_content, r.font_name, r.font_size,
                                                                is_inline, is_heading, hash_key)
    return r, error if error

    r.svg_output = adjusted_svg[:svg_output]
    r.svg_width = adjusted_svg[:svg_width]

    unless cache_dir.nil? # cache to disk the generated svg and width data
      L('Writing svg content and width to RAM')
      @@cached_svg_output[hash_key] = r.svg_output
      @@cached_svg_width[hash_key] = r.svg_width

      L('Writing svg content and width to DISK')
      File.write(r.svg_file_path, r.svg_output)
      cached_svg_width_file_path = get_cached_svg_width_path(cache_dir, hash_key)
      File.write(cached_svg_width_file_path, r.svg_width)

      L('returning NEWLY CACHED path, width, and content for hash_key: ' + hash_key)
      return r
    end

    # no caching, use original Tempfile method.
    L('no caching.  writing to tempfile')
    r.temp_file_handle = Tempfile.new([PREFIX_STEM, '.svg'])
    self.class.tempfiles << r.temp_file_handle
    file_handle.write(r.svg_output)
    file_handle.close
    # no unlinking here.  unlink after the temp file has been used.

    L('returning uncached temp file path, and svg width')
    r
  end

  private

  def get_hash_key(latex_content, font_name, font_size, is_inline)
    # font_name = get_math_font(node)
    # font_size = get_node_font_size_s(node, is_inline)
    b = (is_inline ? 'true' : 'false')
    data = latex_content + font_name + font_size + b
    Digest::MD5.hexdigest(data).freeze
  end

  def get_adjusted_svg_from_node(latex_content, math_font_name, node_font_size, is_inline, is_heading)
    svg_output, error = stem_to_svg(latex_content, math_font_name, is_inline)

    if svg_output == ''
      s = "No svg produced when adjusting LaTeX:\n" + latex_content
      logger.error(s)
      error = s
    end

    return nil, error unless error.nil?

    svg_doc = REXML::Document.new(svg_output)

    # cleanup outline
    svg_doc.root.attributes['shape-rendering'] = 'geometricPrecision'
    svg_doc.root.elements.delete_all('style')

    svg_output = adjust_svg_color(svg_output, @font_color)

    if !is_inline

      svg_default_font_size = FALLBACK_FONT_SIZE
      scaling_factor = node_font_size.to_f / svg_default_font_size

      svg_width = (svg_doc.root.attributes['width'].to_f * POINTS_PER_EX) || raise('No width found in SVG')
      svg_width *= scaling_factor
    elsif is_inline
      svg_output, svg_width = adjust_svg_to_match_text(svg_doc, node_font_size, is_heading)
    end

    [svg_output: svg_output, svg_width: svg_width]
  end

  def get_adjusted_svg_and_set_cached_width(latex_content, math_font_name, node_font_size, is_inline, is_heading,
                                            hash_key)
    adjusted_svg, error = get_adjusted_svg_from_node(latex_content, math_font_name, node_font_size, is_inline,
                                                     is_heading)

    return nil, error unless error.nil?

    @@cached_svg_width[hash_key] = adjusted_svg[:svg_width]

    adjusted_svg
  end

  def get_cached_svg_file_path(cache_dir, hash_key)
    File.join(cache_dir, PREFIX_STEM + hash_key + '.svg')
  end

  def get_cached_svg_width_path(cache_dir, hash_key)
    File.join(cache_dir, PREFIX_WIDTH + hash_key)
  end

  def get_cached_svg_width(cache_dir, hash_key)
    unless @@cached_svg_width[hash_key] # not cached; read from file
      file_name = get_cached_svg_width_path(cache_dir, hash_key)
      svg_width = File.read(file_name).to_f
      L('WIDTH loaded from DISK to ram for hash_key: ' + hash_key)
      @@cached_svg_width[hash_key] = svg_width.freeze
    end

    svg_width = @@cached_svg_width[hash_key]
    L('Returning WIDTH: ' + svg_width.to_s + ' from RAM for hash_key: ' + hash_key)
    svg_width
  end

  def get_cached_svg_output(cache_dir, hash_key)
    unless @@cached_svg_output[hash_key] # read from file
      file_name = get_cached_svg_file_path(cache_dir, hash_key)
      svg_content = File.read(file_name)
      L('DATA loaded from DISK to ram for hash_key: ' + hash_key)
      @@cached_svg_output[hash_key] = svg_content.freeze
    end

    L('Returning DATA from RAM for hash_key: ' + hash_key)
    @@cached_svg_output[hash_key]
  end

  def get_math_font_name(_node)
    # mathjax v4 is more difficult to configure.
    # node.document.attributes[ATTRIBUTE_FONT] || MATHJAX_DEFAULT_FONT_FAMILY
    MATHJAX_DEFAULT_FONT_FAMILY
  end

  def is_node_heading(node)
    return true if node.parent.context == :section || node.parent.is_a?(Asciidoctor::Section)

    false
  end

  def get_node_font_size_s(node, is_inline)
    theme = (load_theme node.document)

    # 1. Check if the math is inside a Section Title
    if is_inline && is_node_heading(node)
      level = node.parent.level
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

    # remove any outlines -- looks grainy/aliased/pixilated
    svg_output.gsub!(/stroke=["'][^"']+["']/, 'stroke="none"')
    svg_output.gsub!(/stroke-width=["'][^"']+["']/, 'stroke-width="0"')

    [svg_output, error]
  end

  # called when stem is an inline block
  # @param [REXML::Document] rexml_doc
  # @return [string, float]
  def adjust_svg_to_match_text(rexml_doc, node_font_size, is_heading)
    f_scale = if is_heading
                SCALE_INLINE_HEADING_DEFAULT
              else
                SCALE_INLINE_BODY_DEFAULT
              end

    target_height_pt = node_font_size.to_f * f_scale

    # 2. CALCULATE THE SCALE
    begin
      root = rexml_doc.root

      # Grab the ViewBox to find the internal aspect ratio
      vb = root.attributes['viewBox']&.split(/\s+/)&.map(&:to_f) || [0, 0, 1000, 1000]
      aspect_ratio = vb[2] / vb[3]

      target_width_pt = target_height_pt * aspect_ratio

      # 3. APPLY TO SVG ROOT
      root.attributes['width'] = "#{target_width_pt.round(2)}pt"
      root.attributes['height'] = "#{target_height_pt.round(2)}pt"

      svg_output = rexml_doc.to_s

      # IMPORTANT: Returning target_width_pt tells Asciidoctor how much
      # horizontal space to move the cursor forward!
      [svg_output, target_width_pt]
    rescue StandardError
      [svg_content, 0.0]
    end
  end

  def find_font_context(node)
    while node
      return node unless node.is_a?(Asciidoctor::Inline)

      node = node.parent
    end
    node
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
