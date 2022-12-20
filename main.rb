require "debug"
require "yaml"
require "json"

require "bundler/setup"
require "yajl" # gem is yajl-ruby

require_relative "lib/client"
require_relative "lib/redis"

trap "SIGINT" do
  puts "Exiting..."
  exit 130
end

client = ActiveDeployment::Client.instance

initial_response = client.get("apis/ruby.love/v1/redis")
initial_response.fetch("items").each do |object|
  ActiveDeployment::Redis.new(object).upsert
end
resource_version = initial_response.fetch("metadata").fetch("resourceVersion")

parser = Yajl::Parser.new
parser.on_parse_complete = lambda do |response|
  object = response.fetch("object")
  type = response.fetch("type")

  unless type == "BOOKMARK"
    puts "#{type}: #{object.fetch('metadata').fetch('name')}"
    redis = ActiveDeployment::Redis.new(object)
  end

  case type
  when "ADDED", "MODIFIED"
    redis.upsert
  when "DELETED"
    redis.delete
  when "BOOKMARK"
    resource_version = response.fetch("object").fetch("metadata").fetch("resourceVersion")
    puts "BOOKMARK: #{resource_version}"
  else
    puts "Unhandled response type 😱"
    pp response
  end
end

client.watch("apis/ruby.love/v1/redis", resource_version: -> { resource_version }) do |chunk|
  parser << chunk
end
