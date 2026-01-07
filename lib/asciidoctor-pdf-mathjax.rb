require 'asciidoctor-pdf' unless Asciidoctor::Converter.for 'pdf'
require 'open3'
require 'tempfile'
require 'rexml/document'
require 'ttfunk'
require 'asciimath'

require 'zlib'

POINTS_PER_EX = 6
MATHJAX_DEFAULT_COLOR_STRING = 'currentColor'
MATHJAX_DEFAULT_FONT_FAMILY = 'TeX'

FALLBACK_FONT_SIZE = 12
FALLBACK_FONT_STYLE = 'normal'
FALLBACK_FONT_FAMILY = 'Arial'
FALLBACK_FONT_COLOR = '#000000'

ATTRIBUTE_FONT = 'math-font'
ATTRIBUTE_CACHE_DIR = 'math-cache-dir'
PREFIX_STEM = 'stem-'
PREFIX_WIDTH = 'width-' # width cache files

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

      svg_info, = get_svg_info(node, false)
      svg_output = svg_info[:svg_output]
      latex_content = svg_info[:latex_content]

      # noinspection RubyResolve
      code_padding = @theme.code_padding
      if svg_output == ''
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

          svg_width = svg_info[:svg_width]
          file_path = svg_info[:file_path]
          temp_handle = svg_info[:temp_handle]
          L('Prawn embed path: ' + file_path)
          L('Prawn embed width:' + svg_width.to_s)

          pad_box code_padding, node do
            image_obj = image file_path, position: :center, width: svg_width, height: nil
            logger.debug "Successfully embedded stem block (as latex) #{latex_content} as SVG image" if image_obj
          rescue Prawn::Errors::UnsupportedImageType => e
            logger.warn "Unsupported image type error: #{e.message}"
          rescue StandardError => e
            logger.warn "Failed embedding SVG: #{e.message}"
          end
        ensure
          temp_handle.unlink if temp_handle
        end
      end
    end
    theme_margin :block, :bottom, (next_enclosed_block node)
  end

  def convert_inline_quoted(node)
    svg_info, error = get_svg_info(node, true)
    svg_output = svg_info[:svg_output]
    latex_content = svg_info[:latex_content]
    return super if latex_content == ''

    if svg_output == ''
      logger.warn "Error processing stem: #{error || 'No SVG output'}"
      return super
    end

    # removed svg temp file handle creation

    begin
      # removed writing of adjusted svg, and closing of handle

      file_path = svg_info[:file_path]
      svg_width = svg_info[:svg_width]
      math_font = get_math_font(node).freeze

      if error.nil?
        logger.debug "Successfully embedded stem inline #{node.text} with font #{math_font} as SVG image"
        quoted_text = "<img src=\"#{file_path}\" format=\"svg\" width=\"#{svg_width}\" alt=\"#{node.text}\">"
        node.id ? %(<a id="#{node.id}">#{DummyText}</a>#{quoted_text}) : quoted_text
      end
    rescue StandardError => e
      logger.warn "Failed to process SVG: #{e.message}"
      super
    end
  end

  protected

  # return {file_path, svg_width, temp_handle, inline_nil_latex, inline_nil_svg}
  def get_svg_info(node, is_inline)
    if is_inline
      node_arg1 = node.text
      node_arg2 = node.type
    else
      node_arg1 = node.content
      node_arg2 = node.style.to_sym
    end
    latex_content = extract_latex_content(node_arg1, node_arg2)

    return { svg_output: '', latex_content: '' } if latex_content.nil?

    empty_reply = { svg_output: '', latex_content: latex_content }

    math_font = get_math_font(node).freeze
    cache_dir = (node.document.attributes[ATTRIBUTE_CACHE_DIR] || nil).freeze

    hash_key = get_hash_key(latex_content, math_font, is_inline)

    unless cache_dir.nil? # caching enabled
      unless @@cache_dir_init_done # ensure directory exists
        puts('Cache directory set to: ' + cache_dir)
        L('INIT cache dir: ' + cache_dir)
        @@cache_dir_init_done = true
        FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)
      end

      cached_svg_file_path = get_cached_svg_file_path(cache_dir, hash_key)

      unless @@cached_svg_output[hash_key].nil? # read from memory
        svg_width = get_cached_svg_width(cache_dir, hash_key)
        svg_output = get_cached_svg_output(cache_dir, hash_key)
        L('returning RAM cached data for hash_key: ' + hash_key)
        return { file_path: cached_svg_file_path, svg_output: svg_output, svg_width: svg_width,
                 latex_content: latex_content }
      end

      if File.exist?(cached_svg_file_path)
        svg_width = get_cached_svg_width(cache_dir, hash_key)
        svg_output = get_cached_svg_output(cache_dir, hash_key)
        L('returning DISK cached data for hash_key: ' + hash_key)
        return { file_path: cached_svg_file_path, svg_output: svg_output, svg_width: svg_width,
                 latex_content: latex_content }
      end
    end

    # caching disabled, or file doesn't exist in cache yet, so create
    L('GENERATING data for hash_key:' + hash_key + ' -- Latex content: ' + latex_content)

    adjusted_svg, error = get_adjusted_svg_and_set_cached_width(node, latex_content, is_inline, math_font, hash_key)
    return empty_reply, error if error

    svg_output = adjusted_svg[:svg_output]
    svg_width = adjusted_svg[:svg_width]

    unless cache_dir.nil? # cache to disk the generated svg and width data
      L('Writing svg content and width to RAM')
      @@cached_svg_output[hash_key] = svg_output
      @@cached_svg_width[hash_key] = svg_width

      L('Writing svg content and width to DISK')
      File.write(cached_svg_file_path, svg_output)
      cached_svg_width_file_path = get_cached_svg_width_path(cache_dir, hash_key)
      File.write(cached_svg_width_file_path, svg_width)

      L('returning NEWLY CACHED path, width, and content for hash_key: ' + hash_key)
      return { file_path: cached_svg_file_path, svg_output: svg_output, svg_width: svg_width,
               latex_content: latex_content }
    end

    # no caching, use original Tempfile method.
    L('no caching.  writing to tempfile')
    file_handle = Tempfile.new(['stem', '.svg'])
    self.class.tempfiles << file_handle
    file_handle.write(svg_output)
    file_handle.close
    # no unlinking here.  unlink after the temp file has been used.

    L('returning uncached temp file path, and svg width')
    { file_path: file_handle.path, svg_output: svg_output, svg_width: svg_width,
      temp_handle: file_handle }
  end

  private

  def get_hash_key(latex_content, math_font, is_inline)
    b = (is_inline ? 'true' : 'false')
    data = latex_content + math_font + b
    Zlib.adler32(data).to_s(16).freeze
  end

  def get_adjusted_svg_from_node(node, latex_content, is_inline, math_font)
    svg_output, error = stem_to_svg(latex_content, is_inline, math_font)

    if svg_output == ''
      s = "No svg produced when adjusting LaTeX:\n" + latex_content
      logger.error(s)
      error = s
    end

    return nil, error unless error.nil?

    if !is_inline
      svg_output = adjust_svg_color(svg_output, @font_color)
      svg_default_font_size = FALLBACK_FONT_SIZE

      svg_doc = REXML::Document.new(svg_output)
      svg_width = (svg_doc.root.attributes['width'].to_f * POINTS_PER_EX) || raise('No width found in SVG')

      scaling_factor = @font_size.to_f / svg_default_font_size
      svg_width *= scaling_factor

      [svg_output: svg_output, svg_width: svg_width]
    else
      theme = (load_theme node.document)
      svg_output, svg_width = adjust_svg_to_match_text(svg_output, node, theme)
      [svg_output: svg_output, svg_width: svg_width]
    end
  end

  def get_adjusted_svg_and_set_cached_width(node, latex_content, is_inline, math_font, hash_key)
    adjusted_svg, error = get_adjusted_svg_from_node(node, latex_content, is_inline, math_font)

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
      L('Returning cached file width: ' + svg_width.to_s + ' for hash_key: ' + hash_key)
      @@cached_svg_width[hash_key] = svg_width.freeze
    end

    svg_width = @@cached_svg_width[hash_key]
    L('Returning cached ram width: ' + svg_width.to_s + ' for hash_key: ' + hash_key)
    svg_width
  end

  def get_cached_svg_output(cache_dir, hash_key)
    unless @@cached_svg_output[hash_key] # read from file
      file_name = get_cached_svg_file_path(cache_dir, hash_key)
      svg_content = File.read(file_name)
      @@cached_svg_output[hash_key] = svg_content.freeze
    end

    @@cached_svg_output[hash_key]
  end

  def get_math_font(node)
    node.document.attributes[ATTRIBUTE_FONT] || MATHJAX_DEFAULT_FONT_FAMILY
  end

  def L(debug_text)
    logger.debug('PATCH: ' + debug_text)
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

  def stem_to_svg(latex_content, is_inline, math_font)
    js_script = File.join(File.dirname(__FILE__), '../bin/render.js')
    svg_output = nil
    error = nil
    format = is_inline ? 'inline-TeX' : 'TeX'
    begin
      Open3.popen3('node', js_script, latex_content, format, POINTS_PER_EX.to_s,
                   math_font) do |_, stdout, stderr, wait_thr|
        svg_output = stdout.read
        error = stderr.read unless wait_thr.value.success?
      end
    rescue Errno::ENOENT => e
      error = "Node.js executable 'node' was not found. Please install Node.js and ensure 'node' is available on your PATH. Original error: #{e.message}"
      svg_output = nil
    end
    [svg_output, error]
  end

  def adjust_svg_to_match_text(svg_content, node, theme)
    node_context = find_font_context(node)
    logger.debug "Found font context #{node_context} for node #{node}"

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

    # noinspection RubyResolve
    font_catalog = theme.font_catalog
    font_file = font_catalog[font_family][font_style.to_s]

    if font_file && !font_file.include?(File::SEPARATOR)
      font_file = File.join(node.document.attributes['pdf-fontsdir'], font_file)
    end

    font = TTFunk::File.open(font_file)
    raise "Failed opening font file: #{font_file}" unless font

    descender_height = font.horizontal_header.descent.abs
    ascender_height = font.horizontal_header.ascent.abs
    x_height = font.os2.x_height

    unless x_height
      logger.debug "'OS/2' table not found, falling back to estimating font x-height (ex) from glyph"

      cmap_table = font.cmap.tables.find do |table|
        table.format == 4 && table.platform_id == 3 && table.encoding_id == 1 || table.encoding_id == 10
      end
      raise 'No suitable Unicode cmap table found' unless cmap_table

      glyph_id = cmap_table.code_map['x'.ord]
      raise "Glyph for 'x' not found" if glyph_id.nil? || glyph_id == 0

      glyph = font.glyph_outlines.for(glyph_id)
      raise 'Glyph data not available' unless glyph

      x_height = glyph.y_max - glyph.y_min
    end
    logger.debug "Embedding Font: #{font_family} #{font_style}, x-height: #{x_height}, ascender: #{ascender_height}, descender: #{descender_height}"

    units_per_em = font.header.units_per_em.to_f
    total_height = (descender_height.to_f + ascender_height.to_f)

    embedding_text_height = total_height / units_per_em * font_size
    embedding_text_baseline_height = descender_height / units_per_em * font_size

    svg_doc = REXML::Document.new(svg_content)
    svg_width = svg_doc.root.attributes['width'].to_f * POINTS_PER_EX || raise('No width found in SVG')
    svg_height = svg_doc.root.attributes['height'].to_f * POINTS_PER_EX || raise('No height found in SVG')
    view_box = svg_doc.root.attributes['viewBox']&.split(/\s+/)&.map(&:to_f) || raise('No viewBox found in SVG')
    svg_inner_offset = view_box[1]
    svg_inner_height = view_box[3]

    svg_default_font_size = FALLBACK_FONT_SIZE

    # Adjust SVG height and width so that math font matches embedding text
    scaling_factor = font_size.to_f / svg_default_font_size
    svg_width *= scaling_factor
    svg_height *= scaling_factor

    svg_height_difference = embedding_text_height - svg_height
    svg_relative_height_difference = embedding_text_height / svg_height
    embedding_text_relative_baseline_height = embedding_text_baseline_height / embedding_text_height

    logger.debug "Original SVG height: #{svg_height.round(2)}, width: #{svg_width.round(2)}, inner height: #{svg_inner_height.round(2)}, inner offset: #{svg_inner_offset.round(2)}"
    if svg_height_difference < 0
      svg_relative_portion_extending_embedding_text_below = (1 - svg_relative_height_difference) / 2
      svg_relative_baseline_height = embedding_text_relative_baseline_height * svg_relative_height_difference
      svg_inner_relative_offset = svg_relative_baseline_height + svg_relative_portion_extending_embedding_text_below - 1

      svg_inner_offset_new = svg_inner_relative_offset * svg_inner_height
      svg_inner_height_padding = (svg_inner_offset - svg_inner_offset_new) * 0.25 # 25% padding to handle fractions
      svg_inner_height_difference = 2 * svg_inner_height_padding
      svg_inner_height_new = svg_inner_height + svg_inner_height_difference
      svg_inner_height_relative_difference = svg_inner_height_new / svg_inner_height

      logger.debug("svg_inner_offset = #{svg_inner_offset}, svg_inner_height = #{svg_inner_height}, svg_inner_offset_new = #{svg_inner_offset_new}, svg_inner_height_new = #{svg_inner_height_new}")
      logger.debug("svg_inner_offset_diff = #{svg_inner_offset - svg_inner_offset_new}, svg_inner_offset_diff_relative = #{(svg_inner_offset - svg_inner_offset_new) / svg_inner_height}")

      svg_height *= svg_inner_height_relative_difference
      svg_inner_height = svg_inner_height_new
      svg_inner_offset = svg_inner_offset_new - svg_inner_height_padding
    else
      svg_height = embedding_text_height
      svg_inner_height = svg_relative_height_difference * svg_inner_height
      svg_inner_offset = (embedding_text_relative_baseline_height - 1) * svg_inner_height
    end

    view_box[1] = svg_inner_offset
    view_box[3] = svg_inner_height
    svg_doc.root.attributes['viewBox'] = view_box.join(' ')
    svg_doc.root.attributes['height'] = "#{svg_height / POINTS_PER_EX}ex"
    svg_doc.root.attributes['width'] = "#{svg_width / POINTS_PER_EX}ex"
    svg_doc.root.attributes.delete('style')

    logger.debug "Adjusted SVG height: #{svg_height.round(2)}, width: #{svg_width.round(2)}, inner height: #{svg_inner_height.round(2)}, inner offset: #{svg_inner_offset.round(2)}"
    svg_output = adjust_svg_color(svg_doc.to_s, font_color)

    [svg_output, svg_width]
  rescue StandardError => e
    logger.warn "Failed to adjust SVG baseline: #{e.full_message}"
    nil # Fallback to the original if adjustment fails
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
