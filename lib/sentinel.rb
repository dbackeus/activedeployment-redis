module ActiveDeployment
  class Sentinel
    NAME = "activedeployment-redis-sentinel".freeze
    PORT = 26_379
    REPLICAS = 3
    QUORUM = 2

    def initialize(redises)
      @redises = redises
    end

    def upsert
      puts "Upserting sentinel service"
      existing_service = client.get("/api/v1/namespaces/default/services/#{NAME}")
      if existing_service["code"] == 404
        client.post("/api/v1/namespaces/default/services?fieldValidation=Strict", service_payload)
      else
        client.put("/api/v1/namespaces/default/services/#{NAME}?fieldValidation=Strict", service_payload)
      end

      puts "Upserting sentinel configmap"
      existing_sentinel_config = client.get("/api/v1/namespaces/default/configmaps/#{NAME}")
      if existing_sentinel_config["code"] == 404
        client.post("/api/v1/namespaces/default/configmaps", config_payload)
      else
        refresh_config
      end

      puts "Upserting sentinel statefulset"
      sentinel_path = "/apis/apps/v1/namespaces/default/statefulsets/#{NAME}"
      existing_sentinel = client.get(sentinel_path)
      if existing_sentinel["code"] == 404
        client.post("/apis/apps/v1/namespaces/default/statefulsets?fieldValidation=Strict", sentinel_payload)
      else
        client.put("/apis/apps/v1/namespaces/default/statefulsets/#{NAME}?fieldValidation=Strict", sentinel_payload)
      end
    end

    def add(redis)
      @redises << redis
      refresh_config
    end

    def delete(redis)
      @redises.delete @redises.find { |r| r.fetch("metadata").fetch("name") == redis.fetch("metadata").fetch("name") }
      refresh_config
    end

    private

    def refresh_config
      client.put("/api/v1/namespaces/default/configmaps/#{NAME}?fieldValidation=Strict", config_payload)
    end

    def client
      ActiveDeployment::Client.instance
    end

    def service_payload
      {
        apiVersion: "v1",
        kind: "Service",
        metadata: { name: NAME },
        spec: {
          clusterIP: "None",
          ports: [{ port: PORT, targetPort: PORT, name: "sentinel" }],
          selector: {
            "app.kubernetes.io/component" => "sentinel",
            "app.kubernetes.io/part-of" => "activedeployment-redis",
          },
        },
      }
    end

    def config_payload
      redises_monitors = @redises.each_with_object("") do |redis, config|
        name = redis.fetch("metadata").fetch("name")
        replicas = redis.fetch("spec").fetch("replicas")
        config << "sentinel monitor #{name} #{name}-redis-0.#{name}-redis.default.svc.cluster.local 6379 #{QUORUM}\n"
        (replicas - 1).times do |index|
          index += 1
          config << "sentinel known-replica #{name} #{name}-redis-#{index}.#{name}-redis.default.svc.cluster.local 6379\n"
        end
        config << "\n"
      end

      {
        metadata: {
          name: NAME,
          kind: "ConfigMap",
          labels: {
            "app.kubernetes.io/managed-by" => "activedeployment",
            "app.kubernetes.io/part-of" => "activedeployment-redis",
          },
        },
        data: {
          "sentinel.conf" => <<~CONF,
            sentinel announce-hostnames yes
            sentinel resolve-hostnames yes

            #{redises_monitors}

            # NOTE: `sentinel announce-ip <host>` is added via initContainer
          CONF
        },
      }
    end

    def sentinel_payload
      {
        metadata: {
          name: NAME,
          labels: {
            "app.kubernetes.io/component" => "sentinel",
            "app.kubernetes.io/managed-by" => "activedeployment",
            "app.kubernetes.io/name" => "sentinel",
            "app.kubernetes.io/part-of" => "activedeployment-redis",
          },
          annotations: {
            "reloader.stakater.com/auto" => "true",
          },
        },
        spec: {
          replicas: REPLICAS,
          serviceName: NAME,
          selector: {
            matchLabels: {
              "app.kubernetes.io/component" => "sentinel",
              "app.kubernetes.io/part-of" => "activedeployment-redis",
            },
          },
          template: {
            metadata: {
              labels: {
                "app.kubernetes.io/component" => "sentinel",
                "app.kubernetes.io/managed-by" => "activedeployment",
                "app.kubernetes.io/name" => "sentinel",
                "app.kubernetes.io/part-of" => "activedeployment-redis",
              },
            },
            spec: {
              volumes: [
                { name: "tmp-conf", configMap: { name: NAME } },
                { name: "conf", emptyDir: {} },
              ],
              initContainers: [{
                name: "config-generator",
                image: "redis:7.0.7-alpine",
                command: %w[sh -c],
                args: [
                  <<~SH,
                    ls /tmp/redis
                    cp /tmp/redis/sentinel.conf /etc/redis/sentinel.conf
                    cat /etc/redis/sentinel.conf
                    echo "sentinel announce-ip $(hostname).#{NAME}.default.svc.cluster.local" >> /etc/redis/sentinel.conf
                    cat /etc/redis/sentinel.conf
                  SH
                ],
                volumeMounts: [
                  { name: "tmp-conf", mountPath: "/tmp/redis" },
                  { name: "conf", mountPath: "/etc/redis" },
                ],
              }],
              containers: [
                {
                  name: "redis",
                  image: "redis:7.0.7-alpine",
                  command: %w[redis-server /etc/redis/sentinel.conf --sentinel],
                  ports: [{ containerPort: PORT, name: "sentinel", protocol: "TCP" }],
                  livenessProbe: {
                    exec: {
                      command: ["redis-cli", "-p", PORT.to_s, "ping"],
                    },
                  },
                  resources: {
                    limits: {
                      memory: "64Mi",
                    },
                    requests: {
                      cpu: "100m",
                      memory: "64Mi",
                    },
                  },
                  volumeMounts: [
                    { name: "conf", mountPath: "/etc/redis" },
                  ],
                },
              ],
            },
          },
        },
      }
    end
  end
end
