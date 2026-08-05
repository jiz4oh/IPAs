#!/usr/bin/env ruby

require "json"
require "open3"
require "tempfile"

module IpaMetadata
  module_function

  def read_plist_value(plist_path, key)
    output, status = Open3.capture2("plutil", "-extract", key, "raw", "-o", "-", plist_path)
    return nil unless status.success?
    value = output.strip
    value.empty? ? nil : value
  end

  def extract(ipa_path)
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
end

def build_result(ipa_path)
  absolute_path = File.expand_path(ipa_path)
  IpaMetadata.extract(absolute_path).merge(
    "size" => File.size(absolute_path),
    "path" => absolute_path
  )
rescue StandardError => e
  { "path" => absolute_path, "error" => e.message }
end

def run_cli(argv)
  if argv.empty?
    warn "Usage: ruby scripts/extract_ipa_metadata.rb <ipa_path> [ipa_path ...]"
    exit 1
  end

  results = argv.map { |ipa_path| build_result(ipa_path) }
  output = results.length == 1 ? results.first : results
  puts JSON.pretty_generate(output)

  exit 2 if results.any? { |item| item.key?("error") }
end

run_cli(ARGV) if __FILE__ == $PROGRAM_NAME
