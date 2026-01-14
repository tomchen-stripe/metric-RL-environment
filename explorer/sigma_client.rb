#!/usr/bin/env ruby
require 'net/http'
require 'json'
require 'uri'
require 'csv'

class PlainSigmaClient
  def initialize(api_key)
    @api_key = api_key
    @api_base_uri = URI('https://api.stripe.com')
  end

  def execute_query(sql)
    # Step 1: Create query run
    query_run_id = create_query_run(sql)
    puts "Created query run: #{query_run_id}"

    # Step 2: Poll until complete
    file_id = poll_query_run(query_run_id)
    puts "Query completed, file ID: #{file_id}"

    # Step 3: Download result
    csv_content = download_result(file_id)

    # Step 4: Parse CSV to JSON
    parse_csv_to_json(csv_content)
  end

  private

  def create_query_run(sql)
    uri = URI.join(@api_base_uri, '/v1/sigma/query_runs')

    request = Net::HTTP::Post.new(uri)
    request.basic_auth(@api_key, '')
    request['Content-Type'] = 'application/x-www-form-urlencoded'
    request.body = URI.encode_www_form({sql: sql})

    response = make_request(uri, request)
    response['id']
  end

  def poll_query_run(query_run_id)
    max_attempts = 30
    attempt = 0

    loop do
      uri = URI.join(@api_base_uri, "/v1/sigma/query_runs/#{query_run_id}")
      request = Net::HTTP::Get.new(uri)
      request.basic_auth(@api_key, '')

      response = make_request(uri, request)
      status = response['status']

      puts "Attempt #{attempt + 1}: status = #{status}"

      if status == 'succeeded'
        # File is returned as a string ID
        return response['result']['file']
      elsif status == 'failed'
        raise "Query failed: #{response['error']}"
      end

      attempt += 1
      if attempt >= max_attempts
        raise "Query did not complete within #{max_attempts} attempts"
      end

      sleep(2)
    end
  end

  def download_result(file_id)
    # First get file metadata to get the download URL
    uri = URI.join(@api_base_uri, "/v1/files/#{file_id}")
    request = Net::HTTP::Get.new(uri)
    request.basic_auth(@api_key, '')
    
    file_metadata = make_request(uri, request)
    download_url = file_metadata['url']
    
    puts "Downloading from: #{download_url}"
    
    # Download from the files.stripe.com URL
    uri = URI(download_url)
    request = Net::HTTP::Get.new(uri.request_uri)
    request.basic_auth(@api_key, '')

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        raise "Failed to download file: #{response.code} #{response.message}"
      end

      response.body
    end
  end

  def parse_csv_to_json(csv_string)
    lines = csv_string.strip.split("\n")
    return [] if lines.empty?

    csv = CSV.parse(csv_string, headers: true)
    csv.map(&:to_h)
  end

  def make_request(uri, request)
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        raise "HTTP Error #{response.code}: #{response.body}"
      end

      JSON.parse(response.body)
    end
  end
end
