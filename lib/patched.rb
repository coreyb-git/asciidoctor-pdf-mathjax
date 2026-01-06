require 'asciidoctor-pdf' unless Asciidoctor::Converter.for 'pdf'
require 'open3'
require 'tempfile'
require 'rexml/document'
require 'ttfunk'
require 'asciimath'

require 'zlib'

POINTS_PER_EX = 6
MATHJAX_DEFAULT_COLOR_STRING = "currentColor"
MATHJAX_DEFAULT_FONT_FAMILY = "TeX"

FALLBACK_FONT_SIZE = 12
FALLBACK_FONT_STYLE = 'normal'
FALLBACK_FONT_FAMILY = 'Arial'
FALLBACK_FONT_COLOR = '#000000'

ATTRIBUTE_FONT = 'math-font'
ATTRIBUTE_CACHE_DIR = 'math-cache-dir'
PREFIX_STEM = 'stem-'
PREFIX_WIDTH = 'width' #width cache files

class AsciidoctorPDFExtensions < (Asciidoctor::Converter.for 'pdf')
  register_for 'pdf'

  @tempfiles = []
  class << self
    attr_reader :tempfiles
  end

  # patch start
  @@cached_width_data = {} #svg widths
  @@init_done = false

  def get_hash_key(latex_content, math_font, is_inline)
    b = (is_inline ? "true" : "false")
    data = latex_content + math_font + b + @font_color
    return Zlib.adler32(data).to_s(16).freeze
  end

  def get_adjusted_svg_from_node(latex_content, is_inline, math_font)
    svg_output, error = stem_to_svg(latex_content, is_inline, math_font)
    if error != nil
      return nil, error
    end
    if (!is_inline)
      svg_output = adjust_svg_color(svg_output, @font_color)
      svg_default_font_size = FALLBACK_FONT_SIZE

      svg_doc = REXML::Document.new(svg_output)
      svg_width = svg_doc.root.attributes['width'].to_f * POINTS_PER_EX || raise("No width found in SVG")

      scaling_factor = @font_size.to_f / svg_default_font_size
      svg_width = svg_width * scaling_factor

      return [svg_output: svg_output, svg_width: svg_width]
    else
      theme = (load_theme node.document)
      svg_output, svg_width = adjust_svg_to_match_text(svg_output, node, theme)
      return [svg_output: svg_output, svg_width: svg_width]
    end
  end

  def get_adjusted_svg_and_set_cached_width(latex_content, is_inline, math_font)
    adjusted_svg, error = get_adjusted_svg_from_node(latex_content, is_inline, math_font)
    if error != nil
      return nil, error
    end

    @@cached_width_data[hash_key] = adjusted_svg.svg_width

    return adjusted_svg
  end

  def get_cached_svg_path(cache_dir, hash_key)
    return File.join(cache_dir,  PREFIX_STEM + hash_key + '.svg')
  end

  def get_cached_width_path(cache_dir, hash_key)
    return File.join(cache_dir, PREFIX_WIDTH + hash_key)
  end

  def get_cached_width(cache_dir, hash_key)
    if !@@cached_width_data[hash] #read from file
      file_name = get_cached_width_path(cache_dir, hash_key)
      svg_width = File.open(file_name, &:gets)&.strip
      @@cached_width_data[hash] = svg_width
    end

    return @@cached_width_data[hash]
  end

  def get_svg_info(node, is_inline) #return {file_path, svg_width, temp_handle, inline_nil_latex, inline_nil_svg}
    if (is_inline)
      node_arg1 = node.text
      node_arg2 = node.type
    else
      node_arg2 = node.content
      node_arg2 = node.style.to_sym
    end
    latex_content = extract_latex_content(node_arg1, node_arg2)

    math_font = (node.document.attributes[ATTRIBUTE_FONT] || MATHJAX_DEFAULT_FONT_FAMILY).freeze
    cache_dir = (node.document.attributes[ATTRIBUTE_CACHE_DIR] || nil).freeze

    hash_key = get_hash_key(latex_content, math_font, is_inline)

    if (cache_dir != nil)  #caching enabled
      if !@@init_done #ensure directory exists
        @@init_done = true
        FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)
      end

      cached_svg_file_path = get_cached_svg_path(cache_dir, hash_key)
      if File.exist?(cached_svg_file_path) #create cached svg and width files, and store width in dictionary
        return {file_path: cached_svg_file_path, svg_width: get_cached_width(cache_dir, hash_key)}
      end
    end

    # caching disabled, or file doesn't exist in cache yet, so create

    adjusted_svg, error = get_adjusted_svg_and_set_cached_width(node, is_inline, math_font)
    if error
      return nil, error
    end

    if (cache_dir != nil)  #cache to the drive the generated svg and width data
      File.write(cached_svg_file_path, adjusted_svg.svg_output)
      cached_width_file_path = get_cached_width_path(cache_dir, hash_key)
      File.write(cached_width_file_path, adjusted_svg.svg_width)
      return {file_path: cached_svg_file_path, svg_width: get_cached_width(cache_dir, hash_key)}
    end

    #no caching, use original Tempfile method.
    file_handle = Tempfile.new(["stem", ".svg"])
    self.class.tempfiles << file_handle
    file_handle.write(svg_output)
    file_handle.close
    # no unlinking here.  unlink after the temp file has been used.

    return {file_path: file_handle.file_path, svg_width: adjusted_svg.svg_width, temp_handle: file_handle}
  end
  #end of patch


  def convert_stem(node)
    arrange_block node do |_|
      add_dest_for_block node if node.id

      svg_info, error = get_svg_info(node, false)

      # noinspection RubyResolve
      code_padding = @theme.code_padding
      if (svg_info.svg_output.nil || svg_info.svg_output.empty)
        logger.warn "Failed to convert STEM to SVG: #{error} (Fallback to code block)"
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

          pad_box code_padding, node do
            begin
              image_obj = image svg_info.file_path, position: :center, width: svg_info.width, height: nil
              logger.debug "Successfully embedded stem block (as latex) #{latex_content} as SVG image" if image_obj
            rescue Prawn::Errors::UnsupportedImageType => e
              logger.warn "Unsupported image type error: #{e.message}"
            rescue StandardError => e
              logger.warn "Failed embedding SVG: #{e.message}"
            end
          end
        ensure
          if svg_info.temp_handle
            svg_info.temp_handle.unlink
          end
        end
      end
    end
    theme_margin :block, :bottom, (next_enclosed_block node)
  end

  def convert_inline_quoted(node)
    svg_info, error = get_svg_info(node, true)
    return super if svg_info.latex_content_nil?

    if svg_info.svg_output.nil? || svg_info.svg_output.empty?
      logger.warn "Error processing stem: #{error || 'No SVG output'}"
      return super
    end

    # removed svg temp file handle creation

    begin
      # removed writing of adjusted svg, and closing of handle

      if (error == nil)
        #logger.debug "Successfully embedded stem inline #{node.text} with font #{math_font} as SVG image"
        quoted_text = "<img src=\"#{tmp_svg.path}\" format=\"svg\" width=\"#{svg_width}\" alt=\"#{node.text}\">"
        node.id ? %(<a id="#{node.id}">#{DummyText}</a>#{quoted_text}) : quoted_text
      end
    rescue => e
      logger.warn "Failed to process SVG: #{e.message}"
      super
    end
  end

  private

  def extract_latex_content(content, type)
    content = content.strip.gsub("&amp;", "&").gsub("&lt;", "<").gsub("&gt;", ">")
    case type
    when :latexmath
      return content
    when :asciimath
      return AsciiMath.parse(content).to_latex
    else
      return nil
    end
  end

  def adjust_svg_color(svg_output, font_color)
    svg_output.gsub(MATHJAX_DEFAULT_COLOR_STRING, "##{font_color}")
  end

  def stem_to_svg(latex_content, is_inline, math_font)
    js_script = File.join(File.dirname(__FILE__), '../bin/render.js')
    svg_output, error = nil, nil
    format = is_inline ? 'inline-TeX' : 'TeX'
    begin
      Open3.popen3('node', js_script, latex_content, format, POINTS_PER_EX.to_s, math_font) do |_, stdout, stderr, wait_thr|
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
      if node_context.sectname == 'abstract'
        theme_key = 'abstract_title'
      end

      font_family = theme["#{theme_key}_font_family"] || theme['heading_font_family'] || theme['base_font_family'] || FALLBACK_FONT_FAMILY
      font_style = theme["#{theme_key}_font_style"] || theme['heading_font_style'] || theme['base_font_style'] || FALLBACK_FONT_STYLE
      font_size = theme["#{theme_key}_font_size"] || theme['heading_font_size'] || theme['base_font_size'] || FALLBACK_FONT_SIZE
      font_color = theme["#{theme_key}_font_color"] || theme['heading_font_color'] || theme['base_font_color'] || FALLBACK_FONT_COLOR
    elsif node_context
      if node_context.parent.is_a?(Asciidoctor::Section) && node_context.parent.sectname == 'abstract'
        theme_key = :abstract
      else
        theme_key = :base
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
    unless font
      raise "Failed opening font file: #{font_file}"
    end

    descender_height = font.horizontal_header.descent.abs
    ascender_height = font.horizontal_header.ascent.abs
    x_height = font.os2.x_height

    unless x_height
      logger.debug "'OS/2' table not found, falling back to estimating font x-height (ex) from glyph"

      cmap_table = font.cmap.tables.find { |table| table.format == 4 && table.platform_id == 3 && table.encoding_id == 1 || table.encoding_id == 10 }
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
    svg_width = svg_doc.root.attributes['width'].to_f * POINTS_PER_EX || raise("No width found in SVG")
    svg_height = svg_doc.root.attributes['height'].to_f * POINTS_PER_EX || raise("No height found in SVG")
    view_box = svg_doc.root.attributes['viewBox']&.split(/\s+/)&.map(&:to_f) || raise("No viewBox found in SVG")
    svg_inner_offset = view_box[1]
    svg_inner_height = view_box[3]

    svg_default_font_size = FALLBACK_FONT_SIZE

    # Adjust SVG height and width so that math font matches embedding text
    scaling_factor = font_size.to_f / svg_default_font_size
    svg_width = svg_width * scaling_factor
    svg_height = svg_height * scaling_factor

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

      svg_height = svg_height * svg_inner_height_relative_difference
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
  rescue => e
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
