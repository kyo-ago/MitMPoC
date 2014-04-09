#!/usr/bin/env ruby
=begin TracWiki

= CocProxy =

== License ==

Public Domain

=end

require 'webrick'
require 'webrick/httpproxy'
require 'uri'
require 'yaml'
require "pp"
require "pathname"
require "stringio"
require "zlib"
require "optparse"

class CocProxyCommand
  VERSION = "$Revision$"
  DEFAULT_CONFIG = {
    :Port        => 5432,
    :ProxyVia    => false,
    :Logger      => WEBrick::Log.new(nil, 0),
    :AccessLog   => WEBrick::Log.new(nil, 0),
    :FilterDir   => "files",
    :Rules       => [
      "\#{File.basename(req.path_info)}",
      "\#{req.host}\#{req.path_info}",
      "\#{req.host}/\#{File.basename(req.path_info)}",
      ".\#{req.path_info}",
    ]
  }

  def self.run(argv)
    new(argv.dup).run
  end

  def initialize(argv)
    @argv = argv
    @parser = OptionParser.new do |parser|
      parser.banner = <<-EOB.gsub(/^\t+/, "")
        Usage: #$0 [options]
      EOB

      parser.separator ""
      parser.separator "Options:"

      parser.on("-c", "--config CONFIG.yaml") do |config|
        begin
          @config = YAML.load_file(config)
        rescue Errno::ENOENT
          puts "#{config} is not found"
          exit
        end
      end

      parser.on("-p", "--port PORT", "Specify port number. This option overrides any config.") do |port|
        @port = port.to_i
      end

      parser.on("-n", "--no-cache", "Disable cache.") do |port|
        @nocache = true
      end

      parser.on("--disable-double-screen", "Disable loading double_screen.rb") do |c|
        @disable_double_screen = c
      end

      parser.on("--version", "Show version string `#{VERSION}'") do
        puts VERSION
        exit
      end
    end
  end

  def run
    @parser.order!(@argv)
    $stdout.sync = true

    unless @config
      begin
        @config = YAML.load_file("proxy-config.yaml")
        puts "proxy-config.yaml was found. Use it."
      rescue Errno::ENOENT
        @config = {
          "server" => {
          },
        }
        puts "Use default configuration."
      end
    end

    server_config = DEFAULT_CONFIG.update(@config["server"])
    server_config[:Port]    = @port if @port
    server_config[:nocache] = @nocache
    server_config[:ProxyURI] = URI.parse(server_config[:ProxyURI]) if server_config[:ProxyURI]

    unless @disable_double_screen
      begin
        require "double_screen.rb"
      rescue LoadError => e
      end
    end
    puts "Port : #{server_config[:Port]}"
    puts "Dir  : #{server_config[:FilterDir]}/"
    puts "Cache: #{!server_config[:nocache]}"
    puts "Rules:"
    server_config[:Rules].each_with_index do |item, index|
      puts "    #{index+1}. #{item}"
    end

    srv = ArrogationProxyServer.new(server_config)
    trap(:INT) { srv.shutdown }
    srv.start
  end

  class ArrogationProxyServer < WEBrick::HTTPProxyServer
    def proxy_service(req, res)

      referer = req.header["referer"]
      dir = @config[:FilterDir]
      $stderr.puts req.path_info if $DEBUG
      $stderr.puts req.query.inspect if $DEBUG

      content    = ""
      local_path = ""

      @config[:Rules].each do |path|
        path = "#{dir}/#{eval("%Q(#{path})")}"
        $stderr.puts "Checking #{path.to_s}"
        if FileTest.file? path
          puts "Hit Arrogation: #{req.path_info}"
          local_path = path
          content = File.open(path).binmode.read
          break
        end
      end

      req.header.delete("HTTP_IF_MODIFIED_SINCE")

      case
      when content =~ /proxy-replace:\s*(.+)\s*/
        content.sub!(/proxy-replace:\s*(.+)\s*/, "")
        regexp = Regexp.new(Regexp.last_match[1])
        puts "Replace Regexp: #{regexp.source}"
        puts " <= #{local_path}"
        super
        case (res["Content-Encoding"] || "").downcase
        #when "deflate"
        #when "compress"
        when "gzip"
          res["Content-Encoding"] = nil
          res.body = Zlib::GzipReader.wrap(StringIO.new(res.body)) {|gz| gz.read }
        end

        p res

        m = res.body.match(regexp)
        if m && m[1]
          res.body[m.begin(1)..(m.end(1)-1)] = content
        else
          puts "In-place Regexp match failed..."
        end
        res["Content-Length"] = res.body.length
      when content !~ /\A\s*\Z/
        mime_types = WEBrick::HTTPUtils::DefaultMimeTypes.update(@config[:MimeTypes])
        mime_types["manifest"] = "text/cache-manifest"
        res.header["Content-Type"] = WEBrick::HTTPUtils.mime_type(req.path_info, mime_types)
        if req.path_info == "/sdk-core-v40.js"
          res.header["Expires"] = "Wed, 04 Dec 2020 22:07:55 GMT"
          res.header["Cache-Control"] = "max-age=29030400, public"
        end
        res.body = content
        puts "Rewrote: <= #{local_path}"
      else
        @cache = {} if !@cache || req.query.key?("clearcache")
        r = @cache[req.request_uri.to_s]

        if r
          r.instance_variables.each do |i|
            res.instance_variable_set(i, r.instance_variable_get(i))
          end
          $stderr.puts "From Cache: #{req.request_uri}"
        else
          super
          unless @config[:nocache]
            @cache[req.request_uri.to_s] = res.dup
            $stderr.puts "Cached: #{req.request_uri}"
          end
        end
      end
      req.header["referer"] = ["http://#{req.header["host"][0]}"]
    rescue Exception => e
      puts $@
      puts $!
    end
  end
end

CocProxyCommand.run(ARGV)