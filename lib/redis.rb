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
      puts "upserting redis server statefulset"
      redis_server_path = "/apis/apps/v1/namespaces/default/statefulsets/#{name}-redis"
      existing_redis_server = client.get(redis_server_path)
      if existing_redis_server["code"] == 404
        client.post("/apis/apps/v1/namespaces/default/statefulsets?fieldValidation=Strict", redis_server_payload)
      else
        client.put("#{redis_server_path}?fieldValidation=Strict", redis_server_payload)
      end

      puts "upserting redis server service"
      existing_service = client.get("/api/v1/namespaces/default/services/#{name}-redis")
      if existing_service["code"] == 404
        client.post("/api/v1/namespaces/default/services?fieldValidation=Strict", redis_service_payload)
      else
        client.put(
          "/api/v1/namespaces/default/services/#{name}-redis?fieldValidation=Strict",
          redis_service_payload,
        )
      end

      puts "upserting redis server master service"
      existing_master_service = client.get("/api/v1/namespaces/default/services/#{name}-redis-master")
      if existing_master_service["code"] == 404
        client.post("/api/v1/namespaces/default/services?fieldValidation=Strict", redis_master_service_payload)
      else
        client.put(
          "/api/v1/namespaces/default/services/#{name}-redis-master?fieldValidation=Strict",
          redis_master_service_payload,
        )
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
          ownerReferences: owner_references,
        },
        spec: {
          replicas: replicas,
          serviceName: "#{name}-redis",
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
                  <<~SH,
                    echo "
                    replica-announce-ip $(hostname).#{name}-redis.default.svc.cluster.local
                    " > /etc/redis/redis.conf
                  SH
                ],
                volumeMounts: [{ name: "conf", mountPath: "/etc/redis" }],
              }],
              containers: [
                {
                  name: "redis",
                  image: "redis:7.0.7-alpine",
                  command: %w[redis-server /etc/redis/redis.conf],
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
                    { name: "data", mountPath: "/data" }, # redis docker image uses /data by convention
                    { name: "conf", mountPath: "/etc/redis" },
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
              ownerReferences: owner_references,
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

    def redis_service_payload
      {
        apiVersion: "v1",
        kind: "Service",
        metadata: {
          name: "#{name}-redis",
          ownerReferences: owner_references,
        },
        spec: {
          clusterIP: "None",
          ports: [{
            port: 6379,
            targetPort: 6379,
            name: "redis",
          }],
          selector: {
            "app.kubernetes.io/component" => "redis",
            "app.kubernetes.io/part-of" => name,
          },
        },
      }
    end

    def redis_master_service_payload
      {
        apiVersion: "v1",
        kind: "Service",
        metadata: {
          name: "#{name}-redis-master",
          ownerReferences: owner_references,
        },
        spec: {
          clusterIP: "None",
          ports: [{
            port: 6379,
            targetPort: 6379,
            name: "redis",
          }],
          selector: {
            "app.kubernetes.io/component" => "redis",
            "app.kubernetes.io/part-of" => name,
            "redis.ruby.love/role" => "master",
          },
        },
      }
    end

    def owner_references
      [{
        apiVersion: "ruby.love/v1",
        blockOwnerDeletion: true,
        controller: true,
        kind: "Redis",
        name: name,
        uid: uid,
      }]
    end
  end
end
