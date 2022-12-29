require "debug"
require "bundler/setup"

require_relative "lib/client"
require_relative "lib/redis"
require_relative "lib/sentinel"

trap "SIGINT" do
  puts "Exiting..."
  exit 130
end

client = ActiveDeployment::Client.instance

puts "Upserting redis servers"
initial_response = client.get("apis/ruby.love/v1/redis")
redises = initial_response.fetch("items")
redises.each do |object|
  ActiveDeployment::Redis.new(object).upsert
end
resource_version = initial_response.fetch("metadata").fetch("resourceVersion")

sentinel = ActiveDeployment::Sentinel.new(redises)
sentinel.upsert

client.watch("apis/ruby.love/v1/redis", resource_version: -> { resource_version }) do |response|
  object = response.fetch("object")
  type = response.fetch("type")

  unless type == "BOOKMARK"
    puts "#{type}: #{object.fetch('metadata').fetch('name')}"
    redis = ActiveDeployment::Redis.new(object)
  end

  case type
  when "ADDED", "MODIFIED"
    redis.upsert
    sentinel.add(object)
  when "DELETED"
    redis.delete
    sentinel.delete(object)
  when "BOOKMARK"
    resource_version = response.fetch("object").fetch("metadata").fetch("resourceVersion")
    puts "BOOKMARK: #{resource_version}"
  else
    puts "Unhandled response type 😱"
    pp response
  end
end
