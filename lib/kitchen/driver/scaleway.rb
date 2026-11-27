# frozen_string_literal: true

#
# Author:: Tensibai (<tensibai@iabis.net>)
#
# Copyright (C) 2026, Tensibai
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "kitchen"
require "etc" unless defined?(Etc)
require "socket" unless defined?(Socket)
require "time" unless defined?(Time.now.iso8601)
require_relative "scaleway_version"
require_relative "scaleway/client"

module Kitchen
  # Namespace for Test Kitchen driver plugins.
  module Driver
    # Test Kitchen driver that provisions Scaleway Instances.
    #
    # The driver talks to the Scaleway Instance v2alpha1 API directly, over
    # HTTPS through {Client}. {#create} launches an Instance and blocks until
    # it is running with a public IPv4 address and an SSH transport that
    # answers; {#destroy} tears it back down.
    #
    # Instances are started from a marketplace image label (for example
    # `ubuntu_jammy` or `debian_bookworm`). Any label is accepted; common
    # platform names are mapped for you through {PLATFORM_IMAGE_LABELS}.
    #
    # @example Minimal `kitchen.yml`
    #   driver:
    #     name: scaleway
    #
    #   platforms:
    #     - name: ubuntu-24
    #
    # @see https://www.scaleway.com/en/developers/api/instance/ Scaleway Instance API
    # @author Tensibai <tensibai@iabis.net>
    class Scaleway < Kitchen::Driver::Base
      kitchen_driver_api_version 2

      plugin_version Kitchen::Driver::SCALEWAY_VERSION

      # Instance statuses Scaleway reports for a server that is running.
      #
      # @return [Array<String>] frozen status list
      LIVE_STATUSES = %w{started}.freeze

      # Maps short, human friendly Test Kitchen platform names onto the
      # Scaleway marketplace image labels they correspond to.
      #
      # A platform name that is not listed here is passed through to the API
      # untouched, so any valid marketplace label (or a custom image label for
      # a private image) can be used directly as a platform name.
      #
      # @return [Hash{String=>String}] frozen platform name to image label map
      # @see #default_image_label
      PLATFORM_IMAGE_LABELS = {
        "almalinux-8" => "almalinux_8",
        "almalinux-9" => "almalinux_9",
        "debian-10" => "debian_buster",
        "debian-11" => "debian_bullseye",
        "debian-12" => "debian_bookworm",
        "debian-13" => "debian_trixie",
        "fedora-40" => "fedora_40",
        "fedora-41" => "fedora_41",
        "ubuntu-18" => "ubuntu_bionic",
        "ubuntu-20" => "ubuntu_focal",
        "ubuntu-22" => "ubuntu_jammy",
        "ubuntu-24" => "ubuntu_noble",
      }.freeze

      # Separator pattern used to turn a delimited configuration string such as
      # `"web, db"` or `"web db"` into a list.
      #
      # @return [Regexp] frozen separator pattern
      # @see #normalize_list
      LIST_SEPARATOR = /\s*,\s*|\s+/

      # Maximum length of a generated server name, chosen to stay inside the
      # 63 octet limit a single DNS label allows.
      #
      # @return [Integer]
      # @see #default_name
      MAX_SERVER_NAME_LENGTH = 63

      # Path prefix of the Instance API used by the driver. Scholarly note: the
      # v2alpha1 version string is what Scaleway serves the current Instance
      # API under today; it is kept in one place so a future GA version can be
      # switched in a single line.
      #
      # @return [String]
      INSTANCE_API_PREFIX = "/instance/v2alpha1/zones"

      default_config :username, "root"
      default_config :port, "22"
      default_config :commercial_type, "PLAY2-PICO"
      default_config :volume_type, "l_ssd"
      default_config(:image, &:default_image_label)
      default_config(:server_name, &:default_name)
      default_config :tags, nil
      default_config :security_group_id, nil
      default_config :user_data, nil
      default_config :server_wait_interval, 8
      default_config :server_wait_timeout, 600
      default_config :api_endpoint, "https://api.scaleway.com"

      default_config :zone do
        ENV["SCW_DEFAULT_ZONE"] || "fr-par-1"
      end

      default_config :project_id do
        ENV["SCW_DEFAULT_PROJECT_ID"] || ENV["SCW_PROJECT_ID"]
      end

      default_config :scw_access_key do
        ENV["SCW_ACCESS_KEY"]
      end

      default_config :scw_secret_key do
        ENV["SCW_SECRET_KEY"]
      end

      required_config :scw_secret_key
      required_config :project_id

      # Keeps API credentials out of computed instance diagnostics.
      # @return [Hash] the diagnostic configuration
      def diagnose
        super.merge(scw_secret_key: "[REDACTED]")
      end

      # Provisions an Instance and waits until it is reachable over SSH.
      #
      # The method is idempotent: if `state` already carries a `:server_id` the
      # Instance is assumed to exist and nothing is provisioned, which keeps a
      # retried `kitchen create` from orphaning the Instance made by the run
      # that failed.
      #
      # @param state [Hash] mutable instance state, populated with
      #   `:server_id`, `:hostname`, `:username` and `:port`
      # @return [void]
      # @raise [Kitchen::ActionFailed] if the API rejects the request, or the
      #   Instance does not become running with a public IPv4 address before
      #   `config[:server_wait_timeout]` elapses
      def create(state)
        if state[:server_id]
          info("Scaleway instance <#{state[:server_id]}> already created.")
          return
        end

        super

        server = create_server
        state[:server_id] = server["id"]
        info("Scaleway instance <#{state[:server_id]}> created.")

        upload_user_data(state[:server_id]) unless config[:user_data].to_s.empty?

        server = wait_for_started(state[:server_id])
        hostname = public_ipv4(server)
        unless hostname
          raise ActionFailed, "The Scaleway instance <#{state[:server_id]}> never " \
            "reported a public IPv4 address."
        end

        state[:hostname] = hostname
        state[:username] = config[:username]
        state[:port] = config[:port]

        instance.transport.connection(state, &:wait_until_ready)
        info("(ssh ready)")
        debug("scaleway:create #{state[:hostname]}")
      end

      # Destroys the Instance recorded in `state`, if there is one.
      #
      # @param state [Hash] mutable instance state; `:server_id` and
      #   `:hostname` are removed once the Instance is gone
      # @return [void]
      # @raise [Kitchen::ActionFailed] if the API rejects the request
      def destroy(state)
        server_id = state[:server_id]
        return if server_id.nil?

        if find_server(server_id).nil?
          info("Scaleway instance <#{server_id}> is already gone.")
        else
          api_call { client.delete(server_path(server_id)) }
          info("Scaleway instance <#{server_id}> destroyed.")
        end

        state.delete(:server_id)
        state.delete(:hostname)
      end

      # Reports what Scaleway currently thinks of the Instance.
      #
      # @param state [Hash] instance state naming the Instance
      # @return [Hash] a Test Kitchen status hash, or the base implementation's
      #   answer when there is no Instance or Scaleway does not know it
      def status(state)
        return super unless state[:server_id]

        server = lookup_server(state[:server_id])
        return super unless server

        {
          live: LIVE_STATUSES.include?(server["status"]),
          state: server["status"],
          source: "driver",
          resource_id: state[:server_id].to_s,
          message: "Scaleway reports the instance as #{server["status"]}",
          checked_at: Time.now.utc.iso8601,
        }
      end

      # Checks the configuration for the mistakes that otherwise surface part
      # way through +create+, once an Instance may already be running.
      #
      # @param state [Hash] mutable instance and driver state
      # @return [Boolean] true when a problem was reported
      def doctor(state)
        problems = []
        problems.concat(secret_key_problems)
        problems.concat(zone_problems)
        problems << "image is not set" if config[:image].to_s.empty?
        problems << "commercial_type is not set" if config[:commercial_type].to_s.empty?

        problems.each { |problem| warn(problem) }
        debug("scaleway:doctor problems=#{problems.inspect}")
        !problems.empty?
      end

      # Submits the Instance create request built from the driver configuration.
      #
      # @return [Hash<String, Object>] the newly created Server object
      # @raise [Kitchen::ActionFailed] if the API rejects the request or returns
      #   a response that cannot be read as a Server
      def create_server
        debug_server_config

        response = api_call { client.post(servers_path, server_create_payload) }
        server = unpack_server(response)
        unless server
          raise ActionFailed, "Could not create the Scaleway instance: the API " \
            "returned an unexpected response (#{response.inspect}). Please check " \
            "that your secret key and project are set correctly."
        end

        server
      end

      # Builds the Instance create request body.
      #
      # A public IPv4 address is requested explicitly through `zonal_ipv4`, and
      # the root volume is created from the configured image label.
      #
      # The server name is read once and reused for the volume name: Test
      # Kitchen re-evaluates a lazily configured `server_name` on every read,
      # so a generated name has to be snapped to a local here or the server
      # and its root volume would wind up with different names.
      #
      # @return [Hash] the create request body
      def server_create_payload
        name = config[:server_name]

        payload = {
          name: name,
          project_id: config[:project_id],
          server_type: config[:commercial_type],
          tags: normalize_list(config[:tags]),
          public_network_interface: {
            ips: [
              { new_ip: { type: "zonal_ipv4" } },
            ],
          },
          volumes: [
            {
              volume_type: config[:volume_type],
              new_volume: {
                name: "#{name}-root",
                image_label: config[:image],
              },
            },
          ],
        }

        if config[:security_group_id]
          payload[:public_network_interface][:security_group_id] = config[:security_group_id]
        end

        payload
      end

      # Uploads cloud-init user data to an Instance, if any was configured.
      #
      # A failure to upload is logged but does not fail `create`: the instance
      # is already running and billable, and a transient API failure should not
      # orphan it.
      #
      # @param server_id [String] the Instance ID
      # @return [void]
      def upload_user_data(server_id)
        api_call do
          client.put("#{server_path(server_id)}/user-data/cloud-init", content: config[:user_data].to_s)
        end
        debug("scaleway:user_data uploaded")
      rescue Kitchen::ActionFailed => e
        warn("Could not upload user data for instance <#{server_id}>: #{e.message}")
      end

      # Polls the API until the Instance reports it is running.
      #
      # @param server_id [String] the Instance ID to poll
      # @return [Hash<String, Object>] the Server object
      # @raise [Kitchen::ActionFailed] if the Instance does not reach the
      #   running status before `config[:server_wait_timeout]` elapses
      def wait_for_started(server_id)
        server = nil

        wait_until("Scaleway instance <#{server_id}> to be running") do
          server = find_server(server_id)
          !server.nil? && server["status"] == "started"
        end

        server
      end

      # Looks an Instance up by ID, treating "not found" as a normal outcome.
      #
      # @param server_id [String] ID of the Instance to fetch
      # @return [Hash<String, Object>, nil] the Server object, or `nil` if it no
      #   longer exists
      # @raise [Kitchen::ActionFailed] for any API error other than a 404
      def find_server(server_id)
        api_call(allow_missing: true) { client.get(server_path(server_id)) }
      end

      # Looks an Instance up without turning an unreachable API into a failure.
      #
      # @param server_id [String] ID of the Instance to fetch
      # @return [Hash<String, Object>, nil] the Server object, or `nil` when it
      #   is gone or Scaleway cannot be reached
      def lookup_server(server_id)
        find_server(server_id)
      rescue Kitchen::ActionFailed
        nil
      end

      # Extracts the public IPv4 address from a Server object.
      #
      # Scaleway reports addresses as CIDR blocks (`1.2.3.4/32`); the subnet
      # length is stripped. The first IPv4 address on the interface is used.
      #
      # @param server [Hash<String, Object>] a Server object
      # @return [String, nil] the public IPv4, or `nil` if none is attached yet
      def public_ipv4(server)
        interface = server && server["public_network_interface"]
        return nil if interface.nil?

        ipv4 = Array(interface["ips"]).find do |ip|
          ip["provisioned_address"].to_s.include?(".")
        end
        return nil if ipv4.nil?

        ipv4["provisioned_address"].to_s.split("/").first
      end

      # Normalizes a Server response that may be bare or wrapped.
      #
      # The v2alpha1 create and get endpoints return the Server object itself;
      # some endpoints wrap it as `{ "server": {...} }`. Accepting both keeps
      # the driver robust to a future change of shape.
      #
      # @param response [Object, nil] the parsed API response
      # @return [Hash<String, Object>, nil] the Server object, or `nil` if the
      #   response does not contain one
      def unpack_server(response)
        case response
        when Hash then response["server"] || (response.key?("id") ? response : nil)
        else nil
        end
      end

      # Runs an API call, converting {Client::ApiError} failures into Test
      # Kitchen errors so users see an actionable message instead of a raw
      # backtrace.
      #
      # @param allow_missing [Boolean] when true, a 404 response yields `nil`
      # @yield the API call to run
      # @return [Object, nil] whatever the block returns, or `nil` for a
      #   tolerated 404
      # @raise [Kitchen::ActionFailed] if the API call fails
      def api_call(allow_missing: false)
        yield
      rescue Client::ApiError => e
        return nil if allow_missing && e.status == 404

        raise ActionFailed, "The Scaleway API request failed: #{e.message}"
      end

      # Polls `block` on a fixed interval until it returns a truthy value.
      #
      # The condition is evaluated before the first sleep, so a resource that is
      # already in the desired state costs no extra wall clock time.
      #
      # @param description [String] what is being waited for, used in log output
      #   and in the timeout message
      # @yield the condition to poll
      # @yieldreturn [Boolean] true once waiting should stop
      # @return [void]
      # @raise [Kitchen::ActionFailed] if `config[:server_wait_timeout]` elapses
      #   before the condition holds
      def wait_until(description)
        interval = config[:server_wait_interval].to_f
        deadline = Time.now + config[:server_wait_timeout].to_f

        loop do
          return if yield

          if Time.now >= deadline
            raise ActionFailed, "Timed out after #{config[:server_wait_timeout]} " \
              "seconds waiting for #{description}"
          end

          info("Waiting on #{description}, retrying in #{interval} seconds")
          sleep(interval)
        end
      end

      # Coerces a configuration value into a list of strings.
      #
      # Accepts the delimited strings (`"a,b"`, `"a, b"`, `"a b"`) that
      # `kitchen.yml` tends to produce, as well as native YAML arrays and bare
      # numbers.
      #
      # @param value [String, Array, Numeric, nil] the configuration value
      # @return [Array<String>] the parsed list; empty when `value` is `nil`
      def normalize_list(value)
        case value
        when nil then []
        when Array then value.map { |item| item.to_s.strip }.reject(&:empty?)
        when String then value.split(LIST_SEPARATOR).reject(&:empty?)
        when Numeric then [value.to_s]
        end
      end

      # Resolves the configured platform name to a Scaleway image label.
      #
      # Looks the platform name up in {PLATFORM_IMAGE_LABELS} and falls back to
      # the platform name verbatim, so labels and private image labels work
      # unchanged.
      #
      # @return [String] a marketplace image label
      # @see PLATFORM_IMAGE_LABELS
      def default_image_label
        PLATFORM_IMAGE_LABELS.fetch(instance.platform.name, instance.platform.name)
      end

      # Builds an Instance name that is unique enough to run many instances side
      # by side without collisions.
      #
      # The name is assembled from four hyphen separated parts, each truncated
      # so the total never exceeds {MAX_SERVER_NAME_LENGTH} octets:
      #
      #     instance name  15
      #     login name     15
      #     local hostname 23
      #     random suffix   7
      #     separators      3
      #     ================
      #     total          63
      #
      # Non-word characters are stripped and underscores become hyphens, since
      # Scaleway only accepts names made of safe characters.
      #
      # @return [String] a generated Instance name of at most 63 characters
      def default_name
        [
          instance.name.gsub(/\W/, "")[0..14],
          (Etc.getlogin || "nologin").gsub(/\W/, "")[0..14],
          Socket.gethostname.gsub(/\W/, "")[0..22],
          Array.new(7) { rand(36).to_s(36) }.join,
        ].join("-").tr("_", "-")[0, MAX_SERVER_NAME_LENGTH]
      end

      # Memoized Scaleway API client.
      #
      # Memoization matters: a single {#create} reaches for the client several
      # times, and each client owns a fresh HTTP connection.
      #
      # @return [Client] client bound to the configured credentials and endpoint
      def client
        @client ||= begin
          debug_client_config
          Client.new(
            secret_key: config[:scw_secret_key],
            project_id: config[:project_id],
            endpoint: config[:api_endpoint]
          )
        end
      end

      # Validates the configured secret key against the API.
      #
      # Lists a page of server types; any non-2xx answer (typically 401) is
      # reported as a credential problem rather than raised.
      #
      # @return [Array<String>] a problem description, or an empty array
      def secret_key_problems
        return ["scw_secret_key is not set"] if config[:scw_secret_key].to_s.empty?

        client.get("#{INSTANCE_API_PREFIX}/#{config[:zone]}/server-types", params: { page_size: 1 })
        []
      rescue ::StandardError => e
        ["Scaleway rejected the configured secret key: #{e.message}"]
      end

      # Validates the configured zone looks like a Scaleway availability zone.
      #
      # @return [Array<String>] a problem description, or an empty array
      def zone_problems
        return [] if config[:zone].to_s.match?(/\A[a-z]{2}-[a-z]+-\d+\z/)

        ["zone '#{config[:zone]}' does not look like a Scaleway zone (e.g. " \
          "fr-par-1); check the SCW_DEFAULT_ZONE variable or the zone setting"]
      end

      # Absolute path of the servers collection for the configured zone.
      #
      # @return [String] the servers path
      def servers_path
        "#{INSTANCE_API_PREFIX}/#{config[:zone]}/servers"
      end

      # Absolute path of a single Server.
      #
      # @param server_id [String] the Instance ID
      # @return [String] the server path
      def server_path(server_id)
        "#{servers_path}/#{server_id}"
      end

      # Writes the resolved Instance configuration to the debug log.
      #
      # @return [void]
      def debug_server_config
        debug("scaleway:name #{config[:server_name]}")
        debug("scaleway:image #{config[:image]}")
        debug("scaleway:commercial_type #{config[:commercial_type]}")
        debug("scaleway:volume_type #{config[:volume_type]}")
        debug("scaleway:zone #{config[:zone]}")
        debug("scaleway:project_id #{config[:project_id]}")
        debug("scaleway:security_group_id #{config[:security_group_id]}")
        debug("scaleway:tags #{config[:tags]}")
      end

      # Writes the resolved API client configuration to the debug log.
      #
      # The secret key is redacted: Test Kitchen debug logs are routinely pasted
      # into bug reports and CI output.
      #
      # @return [void]
      def debug_client_config
        debug("scaleway:api_endpoint #{config[:api_endpoint]}")
        debug("scaleway:scw_access_key #{config[:scw_access_key]}")
        debug("scaleway:scw_secret_key #{redacted_secret_key}")
      end

      # Renders the secret key in a form that is safe to log.
      #
      # Everything but the last four characters is masked, which is enough to
      # tell two keys apart in a bug report without disclosing either.
      #
      # @return [String] the masked secret key
      def redacted_secret_key
        key = config[:scw_secret_key].to_s
        return "*" * key.length if key.length <= 4

        ("*" * (key.length - 4)) + key[-4..]
      end
    end
  end
end
