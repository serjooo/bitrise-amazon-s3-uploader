require 'time'

# --------------------------
# --- Constants & Variables
# --------------------------

@this_script_path = File.expand_path(File.dirname(__FILE__))

# --------------------------
# --- Functions
# --------------------------

def log_fail(message)
  puts "\n\e[31m#{message}\e[0m"
  exit(1)
end

def log_warn(message)
  puts "\e[33m#{message}\e[0m"
end

def log_info(message)
  puts "\n\e[34m#{message}\e[0m"
end

def log_details(message)
  puts "  #{message}"
end

def log_done(message)
  puts "  \e[32m#{message}\e[0m"
end

def s3_object_uri_for_bucket_and_path(bucket_name, path_in_bucket)
  "s3://#{bucket_name}/#{path_in_bucket}"
end

def public_url_for_bucket_and_path(bucket_name, bucket_region, path_in_bucket)
  return "https://s3.amazonaws.com/#{bucket_name}/#{path_in_bucket}" if bucket_region.to_s.empty? || bucket_region == 'us-east-1'
  "https://s3-#{bucket_region}.amazonaws.com/#{bucket_name}/#{path_in_bucket}"
end

def export_output(out_key, out_value)
  IO.popen("envman add --key #{out_key}", 'r+') do |f|
    f.write(out_value.to_s)
    f.close_write
    f.read
  end
end

def upload_file_to_s3(file, base_path_in_bucket, bucket_name, acl_arg, options)
  file_path_in_bucket = "#{base_path_in_bucket}/#{File.basename(file)}"
  file_full_s3_path = s3_object_uri_for_bucket_and_path(bucket_name, file_path_in_bucket)
  public_url_file = public_url_for_bucket_and_path(bucket_name, options[:bucket_region], file_path_in_bucket)
  log_info("Deploy info for file #{file}:")
  log_details("* Access Level: #{options[:acl]}")
  log_details("* File: #{public_url_file}")
  fail "Failed to upload file: #{file}" unless do_s3upload(file, file_full_s3_path, acl_arg)
  return public_url_file
end

def do_s3upload(sourcepth, full_destpth, aclstr)
  system(%Q{aws s3 cp "#{sourcepth}" "#{full_destpth}" --acl "#{aclstr}"})
end

# -----------------------
# --- Main
# -----------------------

# `file_paths` should be a comma-separated string of file paths.
if ENV['file_path']
  log_warn("ENV['file_path'] is deprecated and will be removed in a future release. Please use ENV['file_paths'] instead.")
end

options = {
  files: (ENV['file_paths'] || ENV['file_path'] || '').split(',').map(&:strip),
  app_slug: ENV['app_slug'],
  build_slug: ENV['build_slug'],
  access_key: ENV['aws_access_key'],
  secret_key: ENV['aws_secret_key'],
  bucket_name: ENV['bucket_name'],
  bucket_region: ENV['bucket_region'],
  path_in_bucket: ENV['path_in_bucket'],
  acl: ENV['file_access_level']
}

log_info('Configs:')
options.each { |key, value| log_details("* #{key}: #{value || 'N/A'}") }

status = 'success'
begin
  #
  # Validate options
  fail 'No files specified for upload. Terminating.' if options[:files].empty?
  fail 'Missing required input: app_slug' if options[:app_slug].to_s.eql?('')
  fail 'Missing required input: build_slug' if options[:build_slug].to_s.eql?('')
  fail 'Missing required input: aws_access_key' if options[:access_key].to_s.eql?('')
  fail 'Missing required input: aws_secret_key' if options[:secret_key].to_s.eql?('')
  fail 'Missing required input: bucket_name' if options[:bucket_name].to_s.eql?('')
  fail 'Missing required input: file_access_level' if options[:acl].to_s.eql?('')

  #
  # AWS configs
  ENV['AWS_ACCESS_KEY_ID'] = options[:access_key]
  ENV['AWS_SECRET_ACCESS_KEY'] = options[:secret_key]
  ENV['AWS_DEFAULT_REGION'] = options[:bucket_region] unless options[:bucket_region].to_s.empty?

  base_path_in_bucket = options[:path_in_bucket] || "bitrise_#{options[:app_slug]}/#{Time.now.utc.to_i}_build_#{options[:build_slug]}"

  # supported: private, public_read
  acl_arg = case options[:acl]
            when 'public_read' then 'public-read'
            when 'private' then 'private'
            else fail "Invalid ACL option: #{options[:acl]}"
            end

  log_info("Uploading files to S3")

  @public_urls ||= []
  options[:files].each do |file|
    log_info("Uploading file #{file} to S3...")
    fail "File not found: #{file}" unless File.exist?(file)
    @public_urls << upload_file_to_s3(file, base_path_in_bucket, options[:bucket_name], acl_arg, options)
  end

  if @public_urls.size == 1
    export_output('S3_UPLOAD_STEP_URL', @public_urls.first)
  else
    export_output('S3_UPLOAD_STEP_URLS', @public_urls.join(','))
  end

  log_details('Public URLs:')
  @public_urls.each { |url| log_details("* #{url}") }
  log_done('Upload process completed successfully')

rescue => ex
  status = 'failed'
  log_fail(ex.message)
ensure
  export_output('S3_UPLOAD_STEP_STATUS', status)
  log_done("Status: #{status}")
end
