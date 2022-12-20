module ActiveDeployment
  class Redis
    attr_reader :cpu, :memory, :name, :replicas, :resource_version, :uid

    def initialize(resource)
      metadata = resource.fetch("metadata")

      @cpu = resource.fetch("spec").fetch("cpu")
      @memory = resource.fetch("spec").fetch("memory")
      @name = metadata.fetch("name")
      @replicas = resource.fetch("spec").fetch("replicas")
      @resource_version = metadata.fetch("resourceVersion")
      @uid = metadata.fetch("uid")
    end

    def upsert
      existing_stateful_set = client.get("/apis/apps/v1/namespaces/default/statefulsets/#{name}")
      if existing_stateful_set["code"] == 404
        client.post("/apis/apps/v1/namespaces/default/statefulsets?fieldValidation=Strict", stateful_set_payload)
      else
        client.put("/apis/apps/v1/namespaces/default/statefulsets/#{name}?fieldValidation=Strict", stateful_set_payload)
      end
    end

    def delete
      # Might not have to do anything since ownership seems to clear things up automatically?
      # client.delete("/apis/apps/v1/namespaces/default/statefulsets/#{name}")
    end

    private

    def client
      ActiveDeployment::Client.instance
    end

    def stateful_set_payload
      {
        metadata: {
          name: name,
          labels: {
            "app.kubernetes.io/component" => "redis",
            "app.kubernetes.io/managed-by" => "activedeployment",
            "app.kubernetes.io/name" => "redis",
            "app.kubernetes.io/part-of" => name,
          },
          ownerReferences: [{
            apiVersion: "ruby.love/v1",
            blockOwnerDeletion: true,
            controller: true,
            kind: "Redis",
            name: name,
            uid: uid,
          }],
        },
        spec: {
          replicas: replicas,
          selector: {
            matchLabels: {
              "app.kubernetes.io/component" => "redis",
              "app.kubernetes.io/part-of" => name,
            },
          },
          template: {
            metadata: {
              labels: {
                "app.kubernetes.io/component" => "redis",
                "app.kubernetes.io/managed-by" => "activedeployment",
                "app.kubernetes.io/name" => "redis",
                "app.kubernetes.io/part-of" => name,
              }
            },
            spec: {
              containers: [
                {
                  name: "redis",
                  image: "redis:7.0.7-alpine",
                  ports: [{ containerPort: 6379, name: "redis", protocol: "TCP" }],
                  livenessProbe: {
                    exec: {
                      command: %w[redis-cli ping],
                    },
                  },
                  resources: {
                    limits: {
                      cpu: cpu,
                      memory: memory,
                    },
                    requests: {
                      cpu: cpu,
                      memory: memory,
                    },
                  },
                },
              ],
            },
          },
        },
      }
    end
  end
end
