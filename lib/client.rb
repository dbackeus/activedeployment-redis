require "faraday"
require "json"
require "yajl" # gem is yajl-ruby
require "yaml"

module ActiveDeployment
  class Client
    class HttpError < StandardError
      attr_reader :response

      def initialize(response)
        @response = response
      end
    end

    def self.instance
      @instance ||= new
    end

    def initialize
      kube_config = YAML.load_file(ENV["KUBECONFIG"] || "#{ENV.fetch('HOME')}/.kube/config")

      context =
        if (current_context = kube_config["current-context"])
          kube_config["contexts"].find do |context_entry|
            context_entry.fetch("name") == current_context
          end
        else
          kube_config["contexts"].first
        end.fetch("context")

      cluster = kube_config.fetch("clusters").find do |cluster_entry|
        cluster_entry.fetch("name") == context.fetch("cluster")
      end.fetch("cluster")

      user = kube_config.fetch("users").find do |user_entry|
        user_entry.fetch("name") == context.fetch("user")
      end.fetch("user")

      if (client_key_data = user["client-key-data"])
        client_key = OpenSSL::PKey::EC.new(Base64.decode64(client_key_data))
      elsif user["exec"]
        # command = [user["exec"]["command"]].concat(user["exec"]["args"].to_a).compact.join(" ")
        # token = JSON.parse(`#{command}`).fetch("status").fetch("token")
        raise "TODO: implement OIDC authentication support"
      else
        raise "don't know how to authorize user: #{user}"
      end

      @client = Faraday.new(
        cluster.fetch("server"),
        ssl: {
          client_cert: OpenSSL::X509::Certificate.new(Base64.decode64(user.fetch("client-certificate-data"))),
          client_key: client_key,
          verify: false,
        },
        headers: {
          "Content-Type" => "application/json",
          "Accept" => "application/json",
        },
      )
    end

    def get(path)
      JSON.parse @client.get(path).body
    end

    def watch(path, resource_version:, &block)
      params = {
        watch: true,
        allowWatchBookmarks: true,
        resourceVersion: resource_version.call,
      }

      parser = Yajl::Parser.new
      parser.on_parse_complete = block

      puts "watching #{path} from version: #{params[:resourceVersion]}"

      @client.get(path, params) do |request|
        request.options.timeout = 31_536_000 # 1 year in seconds
        request.options.on_data = lambda do |chunk, _total_bytes_received, _env|
          parser << chunk
        end
      end
    end

    def post(path, params)
      response = JSON.parse @client.post(path, params.to_json).body
      pp response if response["kind"] == "Status"
      response
    end

    def put(path, params)
      response = JSON.parse @client.put(path, params.to_json).body
      pp response if response["kind"] == "Status"
      response
    end

    def delete(path)
      response = JSON.parse @client.delete(path).body
      pp response if response["kind"] == "Status"
      response
    end
  end
end
