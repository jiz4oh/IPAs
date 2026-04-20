#!/usr/bin/env ruby

require "json"
require "net/http"
require "open-uri"
require "open3"
require "tempfile"
require "tmpdir"
require "uri"

ROOT = File.expand_path("..", __dir__)
APPS_JSON_PATH = File.join(ROOT, "apps.json")
DATE = Time.now.utc.strftime("%Y-%m-%d")

def github_get(path)
  uri = URI("https://api.github.com#{path}")
  request = Net::HTTP::Get.new(uri)
  request["Accept"] = "application/vnd.github+json"
  token = ENV["GITHUB_TOKEN"]
  request["Authorization"] = "Bearer #{token}" if token && !token.empty?

  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      raise "GitHub API request failed for #{path}: #{response.code} #{response.body}"
    end
    JSON.parse(response.body)
  end
end

def read_plist_value(plist_path, key)
  output, status = Open3.capture2("plutil", "-extract", key, "raw", "-o", "-", plist_path)
  return nil unless status.success?
  value = output.strip
  value.empty? ? nil : value
end

def extract_metadata(ipa_path)
  entries, status = Open3.capture2("zipinfo", "-1", ipa_path)
  raise "Failed to inspect IPA: #{ipa_path}" unless status.success?

  info_path = entries.lines.find { |line| line.match?(%r{^Payload/[^/]+\.app/Info\.plist$}) }&.strip
  raise "Info.plist not found in #{ipa_path}" unless info_path

  Tempfile.create(["Info", ".plist"]) do |plist|
    system("unzip", "-p", ipa_path, info_path, out: plist.path, err: File::NULL) || raise("Failed to extract #{info_path}")
    plist.flush

    {
      "bundleIdentifier" => read_plist_value(plist.path, "CFBundleIdentifier"),
      "version" => read_plist_value(plist.path, "CFBundleShortVersionString"),
      "buildVersion" => read_plist_value(plist.path, "CFBundleVersion")
    }
  end
end

apps_json = JSON.parse(File.read(APPS_JSON_PATH))
managed_apps = apps_json.fetch("apps").select { |app| app["upstream"].is_a?(Hash) && app["upstream"]["repo"] }

Dir.mktmpdir("upstream-ipa") do |tmpdir|
  managed_apps.each do |app|
    repo = app.fetch("upstream").fetch("repo")
    release = github_get("/repos/#{repo}/releases/latest")
    asset = release.fetch("assets").find { |item| item["name"].end_with?(".ipa") }
    raise "No IPA asset found for #{repo}" unless asset
    version_entry = app.fetch("versions").first
    raise "No version entry found for #{app.fetch("name")}" unless version_entry

    ipa_path = File.join(tmpdir, asset["name"])
    URI.open(asset.fetch("browser_download_url")) do |remote|
      File.binwrite(ipa_path, remote.read)
    end

    metadata = extract_metadata(ipa_path)
    app["bundleIdentifier"] = metadata.fetch("bundleIdentifier")
    version_entry["version"] = metadata.fetch("version")
    version_entry["buildVersion"] = metadata.fetch("buildVersion")
    version_entry["date"] = DATE
    version_entry["localizedDescription"] = "上游源文件：#{asset.fetch("name")}"
    version_entry["downloadURL"] = asset.fetch("browser_download_url")
    version_entry["size"] = asset.fetch("size")
  end
end

File.write(APPS_JSON_PATH, JSON.pretty_generate(apps_json) + "\n")
