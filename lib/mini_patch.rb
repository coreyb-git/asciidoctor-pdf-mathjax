require 'digest'
require 'open3'
require 'fileutils'

module MathjaxCacheInterceptor
  @@cache_dir ||= nil
  @@svg_data ||= {}

  def set_cache_dir(node)
    @@cache_dir = node.document.attributes['patch-tempdir'] || File.join(__dir__, 'math_cache')
  end

  def convert_stem(node)
    set_cache_dir(node)
    super(node)
  end

  def convert_inline_quoted(node)
    set_cache_dir(node)
    super(node)
  end

  def stem_to_svg(latex_content, is_inline, math_font)
    # 1. Setup the Cache Folder in your project root
    #cache_dir = File.join(__dir__, 'math_cache')

    #Dir.mkdir(@@cache_dir) unless Dir.exist?(@@cache_dir)
    FileUtils.mkdir_p(@@cache_dir) unless Dir.exist?(@@cache_dir)
   
    # 2. Create a unique ID for this formula
    hash = Digest::MD5.hexdigest(latex_content + math_font.to_s + is_inline.to_s)
    cache_path = File.join(@@cache_dir, "#{hash}.svg")

    # 3. FAST PATH: If we have it, return it immediately
    if @@svg_data.key?(hash)
      return @@svg_data[hash]
    end

    if File.exist?(cache_path)
      # puts "USING Cached file: #{cache_path}"
      @@svg_data[hash] = File.read(cache_path)
      #return [File.read(cache_path), nil]
      return @@svg_data[hash]
    end

    # 4. SLOW PATH: Find the renderer script inside the container
    # We search dynamically so we don't have to guess the version number
    js_script = Dir.glob('/usr/lib/ruby/gems/*/gems/asciidoctor-pdf-mathjax-*/bin/render.js').first
    
    # Fallback if the glob fails
    js_script ||= '/usr/lib/ruby/gems/3.3.0/gems/asciidoctor-pdf-mathjax-0.4.0/bin/render.js'

    # 5. Execute Node.js to render the SVG
    ppe = defined?(POINTS_PER_EX) ? POINTS_PER_EX : 8
    format = is_inline ? 'inline-TeX' : 'TeX'
    svg_output, error = nil, nil
    
    begin
      Open3.popen3('node', js_script, latex_content, format, ppe.to_s, math_font) do |_, stdout, stderr, wait_thr|
        svg_output = stdout.read
        if wait_thr.value.success? && !svg_output.empty?
          # SAVE TO CACHE
          @@svg_data[hash] = svg_output
          File.write(cache_path, svg_output)
          # puts "CACHED: Written new math SVG to #{hash}.svg"
        else
          error = stderr.read
          puts "ERROR in Node: #{error}"
        end
      end
    rescue => e
      error = e.message
      puts "ERROR in Patch: #{error}"
    end
    
    [svg_output, error]
  end
end

# 2. Inject this module into the target class
# This places your code "in front" of the methods in AsciidoctorPDFExtensions
AsciidoctorPDFExtensions.prepend(MathjaxCacheInterceptor)
puts "SUCCESS: Cached stem_to_svg patch applied."
