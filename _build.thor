require 'yaml'
class Deploy < Thor
  SITE_DOMAIN = 'http://localhost' # include full domain (http://domain.net) without trailing slash
  CDN_URL = "" # include full domain (http://domain.net) without trailing slash
  CDN_URL_STAGING = "" # include full domain (http://domain.net) without trailing slash
  BUCKET = ""
  BUCKET_STAGING = ""
  SERVER_PROD = "" # host in your SSH config
  SERVER_STAGING = ""
  WEB_DIR = ""

  default_task :production

  desc "amazon BUCKET", "deploys site to specified amazon bucket"
  def amazon(bucket)
    puts "Publishing site to bucket #{bucket}"
    system "ruby #{Build.libs_dir}aws_s3_sync.rb #{Build.build_dir} #{bucket}"
  end

  desc "server SERVER", "deploys site to specified server"
  def server(server)
    puts "Publishing site to server #{server}"
    # rsync -v = verbose, -z = compress, -r = recurse, -c = use checksums to check for new files, -t = preserve modification times, -O = omit directory times
    system "rsync -vzrctO --delete #{Build.build_dir} #{server}:#{WEB_DIR}"
  end

  desc "site CDN BUCKET SERVER", "builds, prepares, and deploys site to specified bucket and server"
  def site(cdn = "", bucket = "", server = "")
    invoke "build:production", [cdn]
    unless bucket.empty?
      invoke "build:gzip", [] # gzip here only for amazon's sake
      invoke :amazon, [bucket]
    end
    unless server.empty?
      invoke :server, [server]

      # specify additional tasks here to upload items to server from external folder
    end
  end

  desc "production", "builds, prepares, and deploys site to production environment"
  def production
    invoke :site, [CDN_URL, BUCKET, SERVER_PROD]
  end

  desc "staging", "builds, prepares, and deploys site to staging environment"
  def staging
    # invoke :site, [CDN_URL_STAGING, BUCKET_STAGING, SERVER_STAGING]
  end

  def self.site_domain
    SITE_DOMAIN
  end
end

class BuildHelp < Thor
  BUILD_DIR = "_site/"
  LIBS_DIR = "_libs/"
  # anything in the external directory will not be uploaded when publishing. Before upload, it will be moved from the build_dir to a level up and prepended with _
  EXTERNAL_DIR = "external/"
  IMAGES2X_DIR = "/2x"
  class_option :compressor, :default => "~/Library/Google/compiler-latest/htmlcompressor-1.5.2.jar"
  class_option :port, :aliases => "-p", :default => 3000

  desc "jekyll", "builds static site", :hide => true
  def jekyll(mode = :build, watch = false)
    puts "building static site with jekyll"
    cmd = "jekyll #{mode} --destination #{BUILD_DIR}"
    if mode == :serve
      cmd += " --port #{options[:port]}"
    end
    if watch
      cmd += " --watch"
    end
    system cmd
  end
end

class Dev < BuildHelp
  default_task :dev

  desc "dev", "starts local server and continuously regenerates html and css; wrapper for jekyll --watch"
  def dev
    BuildConfig.configure(:dev)
    invoke :jekyll, [:serve, true]
  end
end

class Build < BuildHelp
  default_task :testing

  def self.build_dir
    BUILD_DIR
  end

  def self.libs_dir
    LIBS_DIR
  end

  def self.processed_external_dir
    "_#{EXTERNAL_DIR}"
  end

  desc "optimize_images", "optimize all PNGs and JPEGs"
  def optimize_images
    system "ruby #{LIBS_DIR}optimize_images.rb #{BUILD_DIR}"
  end

  desc "resize_2x_images", "Any png, jpg, or gif under a /2x directory will be automatically resized to 50% and saved in the directory above. For example, /images/2x/logo.png will get resized and created in /images/logo.png."
  def resize_2x_images
    system "ruby #{LIBS_DIR}resize_2x_images.rb #{BUILD_DIR} #{IMAGES2X_DIR}"
  end

  desc "sprites", "generate sprites"
    def sprites
      # arrays of folder paths containing images to sprite
      # each folder will generate a PNG that matches the name of the folder (ex. images/sprites/labels will generate a images/sprites/labels.png)
      # each folder set contains of original sprite and optional hover and/or active sprites
      folder_sets = [
        # ['images/sprites/labels', 'images/sprites/labels-hover'],
        # ['images/sprites/icons', 'images/sprites/icons-hover'],
        # ['images/sprites/prompts']
      ]

      system "ruby #{LIBS_DIR}sprite_factory_vertical_fixed_grid.rb #{folder_sets.flatten.join(',')}"

      # for each folder set, grab only the ones that have hover and/or active images specified, then combine them into one sprite image
      folder_sets.select{|f| f.length > 1}.each do |folder_arr|
        sprite_images = folder_arr.map {|f| f + ".png"}
        system "ruby #{LIBS_DIR}sprite_combine_hover_active.rb #{sprite_images.join(' ')}"
      end

    end

  desc "clean", "cleans build directory and external directory, if provided", :hide => true
  # method_option :external_dir
  def clean
    puts "cleaning build dir #{BUILD_DIR}"
    system "rm -rf #{BUILD_DIR}*"
    unless EXTERNAL_DIR.empty?
      puts "cleaning external dir _#{EXTERNAL_DIR}"
      system "rm -rf _#{EXTERNAL_DIR}"
    end
  end

  desc "add_base_path", "adds a base path to all files referenced by links or elsewhere", :hide => true
  def add_base_path
    path = BUILD_DIR
    # return everything after first occurance of /
    path = path.slice(path.index('/')..-1)
    # remove trailing /
    path.chop! if path.end_with?('/')
    unless path.empty?
      puts "adding a base path to all files"
      system "ruby #{LIBS_DIR}add_base_path.rb #{BUILD_DIR} #{path}"
    end
  end

  desc "html_compress", "minifies all html", :hide => true
  def html_compress
    puts "minifying all html"
    system "ruby #{LIBS_DIR}html_compress.rb #{BUILD_DIR} #{options[:compressor]}"
  end

  desc "move_external", "this will move the external folder, if specified, out of the build directory", :hide => true
  def move_external
    unless EXTERNAL_DIR.empty?
      puts "moving all external files out of main site"
      system "mv #{BUILD_DIR}#{EXTERNAL_DIR} _#{EXTERNAL_DIR}"
    end
  end

  desc "gzip", "pre-compresses content", :hide => true
  def gzip
    puts "gzipping content"
    system "ruby #{LIBS_DIR}gzip_content.rb #{BUILD_DIR}"
  end

  desc "server", "builds, prepares site for testing environment, and hosts site locally"
  def testing
    invoke :clean
    BuildConfig.configure(:build)
    invoke :jekyll, [:serve]
  end

  # thor 0.14.6 has a bug that forces args to be defined for invoked tasks if the main task accepts an argument that isn't optional.
  # for example, if you remove the [] for `invoke :jekyll, []`, you'll receive an error that the jekyll task was called incorrectly.
  desc "production", "builds and prepares site for a production environment"
  def production(cdn)
    invoke :clean, []
    BuildConfig.configure(:deploy, cdn)
    invoke :jekyll, []
    invoke :add_base_path, []
    invoke :html_compress, []
    invoke :move_external, []
  end
end

class BuildConfig
  DEFAULT_CONFIG = ".config.yml"

  def self.configure(environment, cdn = nil)
    self.read_defaults

    @settings["domain"] = Deploy.site_domain

    if environment != :dev
      @settings["assets"]["compress"]["css"] = "sass"
      @settings["assets"]["compress"]["js"] = "uglifier"
    end
    if environment == :deploy
      @settings["assets"]["baseurl"] = cdn + @settings["assets"]["baseurl"]
    end
    self.write_config
  end

  protected
  def self.read_defaults
    @settings = YAML::load_file DEFAULT_CONFIG
  end

  def self.write_config
    File.open("_config.yml", "w") do |file|
      file.puts "# THIS FILE WAS AUTOGENERATED. Edit #{DEFAULT_CONFIG} to update."
      file.write @settings.to_yaml
    end
  end
end
