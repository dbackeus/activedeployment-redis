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
      puts "upserting statefulset"
      existing_redis_server = client.get("/apis/apps/v1/namespaces/default/statefulsets/#{name}-redis")
      if existing_redis_server["code"] == 404
        client.post("/apis/apps/v1/namespaces/default/statefulsets?fieldValidation=Strict", redis_server_payload)
      else
        client.put("/apis/apps/v1/namespaces/default/statefulsets/#{name}-redis?fieldValidation=Strict", redis_server_payload)
      end

      replicas.times do |replica|
        puts "upserting service #{replica}"
        existing_service = client.get("/api/v1/namespaces/default/services/#{name}-redis-#{replica}")
        if existing_service["code"] == 404
          client.post("/api/v1/namespaces/default/services?fieldValidation=Strict", redis_service_payload(replica))
        else
          client.put(
            "/api/v1/namespaces/default/services/#{name}-redis-#{replica}?fieldValidation=Strict",
            redis_service_payload(replica),
          )
        end
      end

      puts "upserting sentinels"
      existing_sentinel = client.get("/apis/apps/v1/namespaces/default/deployments/#{name}-redis-sentinel")
      if existing_sentinel["code"] == 404
        client.post("/apis/apps/v1/namespaces/default/deployments?fieldValidation=Strict", sentinel_payload)
      else
        client.put("/apis/apps/v1/namespaces/default/deployments/#{name}-redis-sentinel?fieldValidation=Strict", sentinel_payload)
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

    def redis_server_payload
      {
        metadata: {
          name: "#{name}-redis",
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
              volumes: [
                { name: "conf", emptyDir: {} },
              ],
              initContainers: [{
                name: "config-generator",
                image: "redis:7.0.7-alpine",
                command: %w[sh -c],
                args: [
                  <<~SH
                    echo "TODO..."
                  SH
                ],
                #volumeMounts: [{ name: "conf", mountPath: "/etc/redis" }],
              }],
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
                  volumeMounts: [
                    # { name: "conf", mountPath: "/etc/redis" },
                    { name: "data", mountPath: "/data" }, # redis docker image uses /data by convention
                  ],
                },
              ],
            },
          },
          volumeClaimTemplates: [{
            apiVersion: "v1",
            kind: "PersistentVolumeClaim",
            metadata: {
              name: "data",
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
              accessModes: %w[ReadWriteOnce],
              resources: {
                requests: {
                  storage: memory, # TODO: define disk separately in CRD
                },
              },
              storageClassName: "openebs-hostpath",
            },
          }],
        },
      }
    end

    def redis_service_payload(replica)
      {
        apiVersion: "v1",
        kind: "Service",
        metadata: {
          name: "#{name}-redis-#{replica}",
        },
        spec: {
          clusterIP: "None",
          ports: [{
            port: 6379,
            targetPort: 6379,
            name: "redis",
          }],
          selector: {
            "statefulset.kubernetes.io/pod-name" => "#{name}-redis-#{replica}",
          },
        },
      }
    end

    def sentinel_payload
      known_replicas = (1..(replicas - 1)).map do |replica|
        %{echo "sentinel known-replica #{name} $(dig +short mynewsdesk-test-redis-#{replica}.default.svc.cluster.local) 6379" >> /etc/redis/sentinel.conf} # rubocop:disable Layout/LineLength
      end

      {
        metadata: {
          name: "#{name}-redis-sentinel",
          labels: {
            "app.kubernetes.io/component" => "sentinel",
            "app.kubernetes.io/managed-by" => "activedeployment",
            "app.kubernetes.io/name" => "sentinel",
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
          replicas: 3,
          selector: {
            matchLabels: {
              "app.kubernetes.io/component" => "sentinel",
              "app.kubernetes.io/part-of" => name,
            },
          },
          template: {
            metadata: {
              labels: {
                "app.kubernetes.io/component" => "sentinel",
                "app.kubernetes.io/managed-by" => "activedeployment",
                "app.kubernetes.io/name" => "sentinel",
                "app.kubernetes.io/part-of" => name,
              },
            },
            spec: {
              volumes: [
                { name: "conf", emptyDir: {} },
              ],
              initContainers: [{
                name: "config-generator",
                image: "ghcr.io/mynewsdesk/utils:1665679034", # need dig
                command: %w[sh -c],
                args: [
                  <<~SH
                    echo "sentinel monitor #{name} $(dig +short mynewsdesk-test-redis-0.default.svc.cluster.local) 6379 2" >> /etc/redis/sentinel.conf

                    #{known_replicas.join("\n")}
                  SH
                ],
                volumeMounts: [{ name: "conf", mountPath: "/etc/redis" }],
              }],
              containers: [
                {
                  name: "redis",
                  image: "redis:7.0.7-alpine",
                  command: %w[redis-server /etc/redis/sentinel.conf --sentinel],
                  ports: [{ containerPort: 26379, name: "sentinel", protocol: "TCP" }],
                  livenessProbe: {
                    exec: {
                      command: %w[redis-cli -p 26379 ping],
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
