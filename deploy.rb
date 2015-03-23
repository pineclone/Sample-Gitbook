#!/usr/bin/env ruby

require 'optparse'
require 'fileutils'
require 'thread'

require 'rubygems'
require 'bundler/setup'

require 'aws-sdk'
require 'git'

# Shamelessly stolen from http://avi.io/blog/2013/12/03/upload-folder-to-s3-recursively
# Because multithreaded upload is pretty f-ing sweet
class S3FolderUpload
  attr_reader :folder_path, :total_files, :s3_bucket
  attr_accessor :files

  # Initialize the upload class
  #
  # folder_path - path to the folder that you want to upload
  # bucket - The bucket you want to upload to
  # aws_key - Your key generated by AWS defaults to the environemt setting AWS_KEY_ID
  # aws_secret - The secret generated by AWS
  #
  # Examples
  #   => uploader = S3FolderUpload.new("some_route/test_folder", 'your_bucket_name')
  #
  def initialize(folder_path, bucket, aws_key = ENV['AWS_ACCESS_KEY_ID'], aws_secret = ENV['AWS_SECRET_ACCESS_KEY'])
    @folder_path       = folder_path
    @files             = Dir.glob "#{folder_path}/**/{*,.*}"
    @total_files       = files.length
    @connection        = AWS::S3.new(access_key_id: aws_key, secret_access_key: aws_secret)
    @s3_bucket         = @connection.buckets[bucket]
  end

  # public: Upload files from the folder to S3
  #
  # thread_count - How many threads you want to use (defaults to 5)
  #
  # Examples
  #   => uploader.upload!(20)
  #     true
  #   => uploader.upload!
  #     true
  #
  # Returns true when finished the process
  # This is probably no longer accurate now that there's a puts at the end
  def upload!(thread_count = 5)
    file_number = 0
    mutex       = Mutex.new
    threads     = []
    files       = Array.new @files

    thread_count.times do |i|
      threads[i] = Thread.new {
        until files.empty?
          mutex.synchronize do
            file_number += 1
            Thread.current['file_number'] = file_number
          end
          file = files.pop rescue nil
          next unless file

          # I had some more manipulation here figuring out the git sha
          # For the sake of the example, we'll leave it simple
          #
          path = file.gsub(/^#{folder_path}\//, '')

          print "\rUploading... [#{Thread.current["file_number"]}/#{total_files}]"

          data = File.open file

          next if File.directory? data
          obj = s3_bucket.objects[path]
          obj.write(data, { acl: :public_read })
        end
      }
    end
    threads.each { |t| t.join }
    puts "\rUpload complete!".ljust 80
  end

  # Delete files from S3 not included in path
  def cleanup!
    s3_bucket.objects.each do |obj|
      if !files.include? "#{folder_path}/#{obj.key}"
        puts "Deleting #{obj.key}"
        obj.delete
      end
    end
  end
end

# Parse CLI Options
options = {
  :bucket    => nil,
  :build_dir => 'build',
  :threads   => 8,
  :force     => false,
  :branch    => 'master'
}

parser = OptionParser.new do |opts|
  opts.on('-b', '--bucket=BUCKET', 'S3 Bucket to deploy to (REQUIRED)') do |b|
    options[:bucket] = b
  end

  opts.on('-o', '--output_dir=DIRECTORY', "Build directory (Default: \"#{options[:build_dir]}\")") do |o|
    options[:build_dir] = o
  end

  opts.on('-B', '--branch=BRANCH', "Checkout specified branch before building (Default: \"#{options[:branch]}\")") do |br|
    options[:branch] = br
  end

  opts.on('-k', '--aws_key=KEY', 'AWS Upload Key (Default: $AWS_ACCESS_KEY_ID)') do |k|
    ENV['AWS_ACCESS_KEY_ID'] = k
  end

  opts.on('-s', '--aws_secret=SECRET', 'AWS Upload Secret (Default: $AWS_SECRET_ACCESS_KEY)') do |s|
    ENV['AWS_SECRET_ACCESS_KEY'] = s
  end

  opts.on('-t', '--threads=THREADS', Integer, "Number of threads to use for uploading (Default: #{options[:threads]})") do |t|
    options[:threads] = t
  end

  opts.on('-f', '--force', "Force deployment, even if the working directory is not clean") do |f|
    options[:force] = f
  end

  opts.on_tail('-h', '--help', 'Display this help') do
    puts opts
    exit
  end
end

parser.parse!

if options[:bucket] == nil
  puts parser
  exit
end

repo = Git.open '.'

unless options[:force]
  [:added, :changed, :deleted, :untracked].each do |s|
    abort 'Repository status is not clean!' unless repo.status.send(s).empty?
  end
end

original_branch = repo.branch

repo.branches[options[:branch]].checkout unless repo.branches[options[:branch]].current

# abort 'Master branch not currently checked out' unless repo.branches['master'].current

# Build book
system "gitbook build -o \"#{options[:build_dir]}\" -f site content"

# Strip double slashes
gitbook_css = File.join(options[:build_dir], 'gitbook', '*.css')

Dir.glob gitbook_css do |css|
  puts "Removing double slash from #{css}"

  f = File.new(css, 'r+')

  content = f.read.gsub(/\.\/\/fonts/, "./fonts")

  f.truncate 0
  f.rewind

  f.write content
end

# Deploy
uploader = S3FolderUpload.new(options[:build_dir], options[:bucket])
uploader.upload! options[:threads]
uploader.cleanup!

# Cleanup
FileUtils.remove_entry_secure options[:build_dir]

original_branch.checkout unless original_branch.current
