# frozen_string_literal: true

#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "spec_helper"

RSpec.describe Kitchen::Driver::Scaleway do
  subject(:driver) { build_driver }

  let(:state) { {} }

  describe "plugin contract" do
    it "is a Test Kitchen driver" do
      expect(described_class.ancestors).to include(Kitchen::Driver::Base)
    end

    it "reports a display name Test Kitchen can use" do
      expect(driver.name).to eq("Scaleway")
    end

    it "is registered under the name used in kitchen.yml" do
      expect(Kitchen::Driver.const_get(:Scaleway)).to eq(described_class)
    end
  end

  describe "plugin metadata" do
    it "declares the driver API version" do
      expect(described_class.instance_variable_get(:@api_version)).to eq(2)
    end

    it "reports its own gem version to kitchen diagnose" do
      expect(driver.diagnose_plugin[:version])
        .to eq(Kitchen::Driver::SCALEWAY_VERSION)
    end
  end

  describe "#status" do
    let(:server) { server_payload }

    it "reports an unknown status with no server in state" do
      expect(driver.status({})).to include(live: nil, state: "unknown")
    end

    it "reports an unknown status when the server is gone" do
      allow(driver).to receive(:find_server).with("server-1234").and_return(nil)

      expect(driver.status(server_id: "server-1234")).to include(state: "unknown")
    end

    it "reports a running server as live" do
      allow(driver).to receive(:find_server).with("server-1234").and_return(server)

      expect(driver.status(server_id: "server-1234")).to include(
        live: true, state: "started", source: "driver", resource_id: "server-1234"
      )
    end

    it "reports a stopped server as not live" do
      allow(driver).to receive(:find_server)
        .and_return(server_payload(status: "stopped"))

      expect(driver.status(server_id: "server-1234")).to include(live: false, state: "stopped")
    end

    it "stamps when the check happened" do
      allow(driver).to receive(:find_server).and_return(server)

      expect(driver.status(server_id: "server-1234")[:checked_at])
        .to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it "reports an unknown status when the API cannot be reached" do
      allow(driver).to receive(:find_server)
        .and_raise(Kitchen::ActionFailed.new("boom"))

      expect(driver.status(server_id: "server-1234")).to include(state: "unknown")
    end
  end

  describe "#doctor" do
    before do
      allow(driver).to receive(:client)
        .and_return(double(get: true))
    end

    it "reports no problem when the configuration is complete" do
      expect(driver.doctor(state)).to be(false)
    end

    it "reports a missing image" do
      d = build_driver(image: nil)
      allow(d).to receive(:client).and_return(double(get: true))

      expect(d.doctor(state)).to be(true)
      expect(logged_output.string).to match(/image is not set/)
    end

    it "reports a zone that is not a Scaleway zone" do
      d = build_driver(zone: "not-a-zone")
      allow(d).to receive(:client).and_return(double(get: true))

      expect(d.doctor(state)).to be(true)
      expect(logged_output.string).to match(/does not look like a Scaleway zone/)
    end

    it "reports a secret key Scaleway rejects" do
      allow(driver).to receive(:client).and_raise(StandardError.new("401"))

      expect(driver.doctor(state)).to be(true)
      expect(logged_output.string).to match(/rejected the configured secret key/)
    end
  end

  describe "configuration defaults" do
    {
      scw_access_key: nil,
      username: "root",
      port: "22",
      commercial_type: "PLAY2-PICO",
      volume_type: "l_ssd",
      api_endpoint: "https://api.scaleway.com",
      zone: "fr-par-1",
      tags: nil,
      security_group_id: nil,
      user_data: nil,
    }.each do |key, value|
      it "defaults #{key} to #{value.inspect}" do
        expect(build_driver({})[key]).to eq(value)
      end
    end

    it "defaults the server name to a generated name" do
      expect(build_driver({})[:server_name]).to match(/\Adefaultubuntu24-/)
    end

    it "defaults the image to the label for the instance platform" do
      expect(build_driver({})[:image]).to eq("ubuntu_noble")
    end

    it "polls on an interval that leaves room for an Instance to boot" do
      driver = Kitchen::Driver::Scaleway.new(
        scw_secret_key: "t", project_id: "p"
      ).finalize_config!(kitchen_instance)

      expect(driver[:server_wait_interval]).to eq(8)
      expect(driver[:server_wait_timeout]).to eq(600)
    end

    describe "overrides" do
      overrides = {
        scw_secret_key: "other-secret",
        scw_access_key: "access-key",
        project_id: "other-project",
        zone: "nl-ams-2",
        api_endpoint: "https://api.example.test",
        username: "admin",
        port: "2222",
        server_name: "puppy",
        image: "debian_bookworm",
        commercial_type: "DEV1-S",
        volume_type: "sbs",
        tags: %w{web db},
        security_group_id: "sg-1",
        user_data: "#cloud-config\n",
        server_wait_interval: 1,
        server_wait_timeout: 30,
      }

      overrides.each do |key, value|
        it "honours an explicit #{key}" do
          expect(build_driver(overrides)[key]).to eq(value)
        end
      end
    end
  end

  describe "configuration from the environment" do
    it "reads the secret key from SCW_SECRET_KEY" do
      ENV["SCW_SECRET_KEY"] = "env-secret"
      ENV["SCW_DEFAULT_PROJECT_ID"] = "env-project"

      expect(build_driver_without_defaults[:scw_secret_key]).to eq("env-secret")
    end

    it "reads the project ID from SCW_DEFAULT_PROJECT_ID" do
      ENV["SCW_SECRET_KEY"] = "t"
      ENV["SCW_DEFAULT_PROJECT_ID"] = "env-project"

      expect(build_driver_without_defaults[:project_id]).to eq("env-project")
    end

    it "falls back to SCW_PROJECT_ID when SCW_DEFAULT_PROJECT_ID is unset" do
      ENV["SCW_SECRET_KEY"] = "t"
      ENV["SCW_PROJECT_ID"] = "legacy-project"

      expect(build_driver_without_defaults[:project_id]).to eq("legacy-project")
    end

    it "prefers SCW_DEFAULT_PROJECT_ID over SCW_PROJECT_ID" do
      ENV["SCW_SECRET_KEY"] = "t"
      ENV["SCW_DEFAULT_PROJECT_ID"] = "preferred-project"
      ENV["SCW_PROJECT_ID"] = "legacy-project"

      expect(build_driver_without_defaults[:project_id]).to eq("preferred-project")
    end

    it "reads the zone from SCW_DEFAULT_ZONE" do
      ENV["SCW_SECRET_KEY"] = "t"
      ENV["SCW_DEFAULT_PROJECT_ID"] = "p"
      ENV["SCW_DEFAULT_ZONE"] = "nl-ams-1"

      expect(build_driver_without_defaults[:zone]).to eq("nl-ams-1")
    end

    it "prefers explicit configuration over the environment" do
      ENV["SCW_DEFAULT_ZONE"] = "nl-ams-1"

      expect(build_driver(zone: "fr-par-2")[:zone]).to eq("fr-par-2")
    end
  end

  describe "required configuration" do
    it "rejects a missing secret key" do
      expect { build_driver_without_defaults }
        .to raise_error(Kitchen::UserError, /scw_secret_key/)
    end

    it "rejects a missing project ID" do
      ENV["SCW_SECRET_KEY"] = "t"

      expect { build_driver_without_defaults }
        .to raise_error(Kitchen::UserError, /project_id/)
    end
  end

  describe "#default_image_label" do
    described_class::PLATFORM_IMAGE_LABELS.each do |platform, label|
      it "maps the #{platform} platform to #{label}" do
        driver = build_driver({}, kitchen_instance(platform: platform))

        expect(driver.default_image_label).to eq(label)
      end
    end

    it "passes an unmapped platform name straight through as a label" do
      driver = build_driver({}, kitchen_instance(platform: "ubuntu_jammy"))

      expect(driver.default_image_label).to eq("ubuntu_jammy")
    end

    it "passes any custom label straight through" do
      driver = build_driver({}, kitchen_instance(platform: "my_golden_image"))

      expect(driver.default_image_label).to eq("my_golden_image")
    end

    describe "PLATFORM_IMAGE_LABELS" do
      it "is frozen" do
        expect(described_class::PLATFORM_IMAGE_LABELS).to be_frozen
      end

      it "only maps onto marketplace style labels" do
        expect(described_class::PLATFORM_IMAGE_LABELS.values).to all(match(/\A[a-z0-9_]+\z/))
      end

      it "has no duplicate labels" do
        labels = described_class::PLATFORM_IMAGE_LABELS.values

        expect(labels.uniq.length).to eq(labels.length)
      end
    end
  end

  describe "#default_name" do
    before do
      allow(Etc).to receive(:getlogin).and_return("user")
      allow(Socket).to receive(:gethostname).and_return("host")
    end

    it "joins the instance name, login, hostname and a random suffix" do
      driver = build_driver({}, kitchen_instance(name: "potatoes"))

      expect(driver.default_name).to match(/\Apotatoes-user-host-[a-z0-9]{7}\z/)
    end

    it "is different on every call" do
      driver = build_driver({})

      expect(driver.default_name).not_to eq(driver.default_name)
    end

    it "falls back to a placeholder when there is no login name" do
      allow(Etc).to receive(:getlogin).and_return(nil)
      driver = build_driver({}, kitchen_instance(name: "potatoes"))

      expect(driver.default_name).to match(/\Apotatoes-nologin-host-/)
    end

    context "with a long hostname" do
      before { allow(Socket).to receive(:gethostname).and_return("ab.c" * 20) }

      it "stays within the 63 character DNS label limit" do
        expect(build_driver({}).default_name.length).to be <= described_class::MAX_SERVER_NAME_LENGTH
      end
    end

    context "with a long hostname, login and instance name" do
      before do
        allow(Etc).to receive(:getlogin).and_return("abcd" * 20)
        allow(Socket).to receive(:gethostname).and_return("efgh" * 20)
      end

      it "uses the full 63 character budget" do
        driver = build_driver({}, kitchen_instance(name: "ijkl" * 20))

        expect(driver.default_name.length).to eq(described_class::MAX_SERVER_NAME_LENGTH)
      end
    end

    context "with punctuation in the login, hostname and instance name" do
      before do
        allow(Etc).to receive(:getlogin).and_return("some.u-se-r")
        allow(Socket).to receive(:gethostname).and_return("a.host-name")
      end

      subject(:name) do
        build_driver({}, kitchen_instance(name: "a.instance-name")).default_name
      end

      it "strips dots, which Scaleway rejects in instance names" do
        expect(name).not_to include(".")
      end

      it "keeps only the three separators" do
        expect(name.count("-")).to eq(3)
      end
    end

    it "turns underscores into hyphens, which Scaleway does accept" do
      driver = build_driver({}, kitchen_instance(name: "my_suite_name"))

      expect(driver.default_name).to start_with("my-suite-name-")
    end
  end

  describe "#create" do
    before do
      stub_server_create
      stub_server_find(servers: [server_payload])
    end

    it "records the server ID in state" do
      driver.create(state)

      expect(state[:server_id]).to eq("server-1234")
    end

    it "records the public IPv4 address as the hostname" do
      driver.create(state)

      expect(state[:hostname]).to eq("1.2.3.4")
    end

    it "strips the /32 prefix Scaleway appends to the address" do
      stub_server_find(servers: [server_payload(ip: "9.8.7.6")])

      driver.create(state)

      expect(state[:hostname]).to eq("9.8.7.6")
    end

    it "records the SSH username and port in state" do
      build_driver(username: "admin", port: "2222").create(state)

      expect(state).to include(username: "admin", port: "2222")
    end

    it "waits for the SSH transport to answer" do
      expect(transport_connection).to receive(:wait_until_ready)

      driver.create(state)
    end

    it "hands the populated state to the transport" do
      expect(transport).to receive(:connection)
        .with(hash_including(hostname: "1.2.3.4", username: "root", port: "22"))

      driver.create(state)
    end

    it "logs that the instance was created" do
      driver.create(state)

      expect(log_output).to include("Scaleway instance <server-1234> created.")
    end

    describe "waiting for the instance to run" do
      it "polls until the instance reports started with a public IPv4 address" do
        stub_server_find(servers: [
          server_payload(status: "starting"),
          server_payload(status: "started", ip: "1.2.3.4"),
        ])

        driver.create(state)

        expect(a_request(:get, server_url)).to have_been_made.times(2)
      end

      it "does not re-fetch the instance once it is started" do
        driver.create(state)

        expect(a_request(:get, server_url)).to have_been_made.once
      end

      it "gives up once the timeout elapses" do
        stub_server_find(servers: [server_payload(status: "starting")])
        driver = build_driver(server_wait_timeout: 0)

        expect { driver.create(state) }
          .to raise_error(Kitchen::ActionFailed, /Timed out after 0 seconds waiting for/)
      end

      it "raises a Test Kitchen error when the instance has no public address" do
        stub_server_find(servers: [server_payload(ip: nil)])
        driver = build_driver({})

        expect { driver.create(state) }
          .to raise_error(Kitchen::ActionFailed, /public IPv4/)
      end

      it "leaves the server ID in state when it times out, so destroy can clean up" do
        stub_server_find(servers: [server_payload(status: "starting")])
        driver = build_driver(server_wait_timeout: 0)

        expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed)
        expect(state[:server_id]).to eq("server-1234")
      end
    end

    describe "when the instance already exists" do
      let(:state) { { server_id: "server-1234", hostname: "1.2.3.4" } }

      it "does not create a second instance" do
        driver.create(state)

        expect(a_request(:post, "#{ScalewayAPI::API_ROOT}/instance/v2alpha1/zones/fr-par-1/servers"))
          .not_to have_been_made
      end

      it "says so in the log" do
        driver.create(state)

        expect(log_output).to include("Scaleway instance <server-1234> already created.")
      end
    end

    describe "pre_create_command" do
      it "runs the configured command before provisioning" do
        driver = build_driver(pre_create_command: "echo hello")
        expect(driver).to receive(:run_command).with("echo hello")

        driver.create(state)
      end

      it "turns a failing command into an ActionFailed" do
        driver = build_driver(pre_create_command: "false")
        allow(driver).to receive(:run_command).and_raise(Kitchen::ShellOut::ShellCommandFailed, "boom")

        expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed, /pre_create_command/)
      end
    end

    describe "when the API rejects the request" do
      it "raises a Test Kitchen error rather than leaking a client backtrace" do
        stub_request(:post, "#{ScalewayAPI::API_ROOT}/instance/v2alpha1/zones/fr-par-1/servers")
          .to_return(status: 401, body: error_payload("unauthorized", "Unable to authenticate you."),
                     headers: ScalewayAPI::JSON_HEADERS)

        expect { driver.create(state) }
          .to raise_error(Kitchen::ActionFailed, /401.*Unable to authenticate you/m)
      end

      it "does not record a server ID" do
        stub_request(:post, "#{ScalewayAPI::API_ROOT}/instance/v2alpha1/zones/fr-par-1/servers")
          .to_return(status: 422, body: error_payload("unprocessable_entity", "invalid server type"),
                     headers: ScalewayAPI::JSON_HEADERS)

        expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed)
        expect(state).to be_empty
      end

      it "raises a clear error when the API returns a success without a server" do
        stub_request(:post, "#{ScalewayAPI::API_ROOT}/instance/v2alpha1/zones/fr-par-1/servers")
          .to_return(status: 200, body: "{}", headers: ScalewayAPI::JSON_HEADERS)

        expect { driver.create(state) }
          .to raise_error(Kitchen::ActionFailed, /unexpected response.*secret key/m)
      end

      it "surfaces the body verbatim when the API answers in plain text" do
        stub_request(:post, "#{ScalewayAPI::API_ROOT}/instance/v2alpha1/zones/fr-par-1/servers")
          .to_return(status: 500, body: "boom")

        expect { driver.create(state) }
          .to raise_error(Kitchen::ActionFailed, /500 boom/)
      end

      it "turns a network failure into a Test Kitchen error" do
        stub_request(:post, "#{ScalewayAPI::API_ROOT}/instance/v2alpha1/zones/fr-par-1/servers")
          .to_raise(Errno::ECONNREFUSED)

        expect { driver.create(state) }
          .to raise_error(Kitchen::ActionFailed, /could not reach/)
      end

      it "raises a Test Kitchen error when the instance lookup fails" do
        stub_request(:get, server_url)
          .to_return(status: 500, body: error_payload("server_error", "oops"),
                     headers: ScalewayAPI::JSON_HEADERS)

        expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed, /500/)
      end
    end
  end

  describe "the Server create request" do
    subject(:body) do
      driver.create(state)
      request_body(created_server_request)
    end

    before do
      stub_server_create
      stub_server_find(servers: [server_payload])
    end

    it "sends the configured server name" do
      build_driver(server_name: "hello").create(state)

      expect(request_body(created_server_request)).to include(name: "hello")
    end

    it "sends the project, type and image label" do
      build_driver(commercial_type: "DEV1-S", image: "debian_bookworm").create(state)

      expect(request_body(created_server_request))
        .to include(project_id: "project-1234", server_type: "DEV1-S")
    end

    it "creates the root volume from the image label, sharing the server name" do
      build_driver(server_name: "potatoes", image: "debian_bookworm").create(state)

      volume = request_body(created_server_request)[:volumes].first
      expect(volume[:new_volume])
        .to include(name: "potatoes-root", image_label: "debian_bookworm")
    end

    it "sends the volume type and asks for a zonal public IPv4 address" do
      build_driver(volume_type: "sbs").create(state)

      body = request_body(created_server_request)
      expect(body[:volumes].first).to include(volume_type: "sbs")
      expect(body[:public_network_interface][:ips]).to eq([{ new_ip: { type: "zonal_ipv4" } }])
    end

    it "sends the security group when configured" do
      build_driver(security_group_id: "sg-1").create(state)

      expect(request_body(created_server_request)[:public_network_interface])
        .to include(security_group_id: "sg-1")
    end

    it "leaves the security group out when none is configured" do
      driver.create(state)

      expect(request_body(created_server_request)[:public_network_interface])
        .not_to have_key(:security_group_id)
    end

    describe "tags" do
      {
        "a single tag" => ["web", %w{web}],
        "a comma separated list" => ["web,db", %w{web db}],
        "a comma and space separated list" => ["web, db", %w{web db}],
        "a space separated list" => ["web db", %w{web db}],
        "a YAML array" => [%w{web db}, %w{web db}],
        "no tags" => [nil, []],
      }.each do |description, (configured, expected)|
        it "sends #{description} as #{expected.inspect}" do
          build_driver(tags: configured).create(state)

          expect(request_body(created_server_request)).to include(tags: expected)
        end
      end
    end

    def created_server_request
      request = nil
      WebMock::RequestRegistry.instance.requested_signatures.each do |signature, _count|
        if signature.method == :post && signature.uri.path == "/instance/v2alpha1/zones/fr-par-1/servers"
          request = signature
        end
      end
      request
    end
  end

  describe "user data" do
    before do
      stub_server_create
      stub_server_find(servers: [server_payload])
    end

    it "uploads the configured script after the instance is created" do
      stub_user_data_upload

      build_driver(user_data: "#cloud-config\npackages: [git]\n").create(state)

      expect(WebMock).to have_requested(:put, "#{server_url}/user-data/cloud-init")
        .with(body: { content: "#cloud-config\npackages: [git]\n" }.to_json)
    end

    it "does not call the user-data endpoint when none is configured" do
      driver.create(state)

      expect(WebMock).not_to have_requested(:put, %r{/user-data/cloud-init})
    end

    it "warns and carries on when the upload fails" do
      stub_user_data_upload(status: 500)

      build_driver(user_data: "#cloud-config\n").create(state)

      expect(log_output).to match(/Could not upload user data/)
    end
  end

  describe "#destroy" do
    let(:state) { { server_id: "server-1234", hostname: "1.2.3.4" } }

    it "deletes the instance and clears the state" do
      stub_server_find(servers: [server_payload])
      stub_server_delete

      driver.destroy(state)

      expect(WebMock).to have_requested(:delete, server_url)
      expect(state).to be_empty
    end

    it "logs that the instance was destroyed" do
      stub_server_find(servers: [server_payload])
      stub_server_delete

      driver.destroy(state)

      expect(log_output).to include("Scaleway instance <server-1234> destroyed.")
    end

    it "does nothing when there is no server in state" do
      driver.destroy({})

      expect(WebMock).not_to have_requested(:delete, %r{/servers/})
    end

    describe "when the instance is already gone" do
      before { stub_server_missing }

      it "does not attempt a delete" do
        driver.destroy(state)

        expect(WebMock).not_to have_requested(:delete, server_url)
      end

      it "still clears the state" do
        driver.destroy(state)

        expect(state).to be_empty
      end

      it "says so in the log" do
        driver.destroy(state)

        expect(log_output).to include("Scaleway instance <server-1234> is already gone.")
      end
    end

    it "raises a Test Kitchen error when the lookup fails for another reason" do
      stub_request(:get, server_url)
        .to_return(status: 401, body: error_payload("unauthorized", "Unable to authenticate you."),
                   headers: ScalewayAPI::JSON_HEADERS)

      expect { driver.destroy(state) }.to raise_error(Kitchen::ActionFailed, /401/)
    end

    it "raises a Test Kitchen error when the delete fails" do
      stub_server_find(servers: [server_payload(status: "started")])
      stub_request(:delete, server_url)
        .to_return(status: 403, body: error_payload("forbidden", "nope"),
                   headers: ScalewayAPI::JSON_HEADERS)

      expect { driver.destroy(state) }.to raise_error(Kitchen::ActionFailed, /403/)
      expect(state[:server_id]).to eq("server-1234")
    end
  end

  describe "the API client" do
    it "is built once and reused across calls" do
      expect(described_class::Client).to receive(:new).once.and_call_original

      stub_server_create
      stub_server_find(servers: [server_payload])
      driver.create(state)
    end

    it "is pointed at the configured API endpoint" do
      stub_request(:post, "https://api.example.test/instance/v2alpha1/zones/fr-par-1/servers")
        .to_return(status: 200, body: server_payload(status: "starting").to_json,
                   headers: ScalewayAPI::JSON_HEADERS)
      stub_request(:get, "https://api.example.test/instance/v2alpha1/zones/fr-par-1/servers/server-1234")
        .to_return(status: 200, body: server_payload.to_json,
                   headers: ScalewayAPI::JSON_HEADERS)

      build_driver(api_endpoint: "https://api.example.test").create(state)

      expect(WebMock)
        .to have_requested(:post, "https://api.example.test/instance/v2alpha1/zones/fr-par-1/servers")
    end

    it "authenticates with the configured secret key" do
      stub_server_create
      stub_server_find(servers: [server_payload])

      build_driver(scw_secret_key: "secret-token").create(state)

      expect(WebMock)
        .to have_requested(:post, "#{ScalewayAPI::API_ROOT}/instance/v2alpha1/zones/fr-par-1/servers")
        .with(headers: { "X-Auth-Token" => "secret-token" })
    end

    it "sends the project as the X-Auth-Project-Id header" do
      stub_server_create
      stub_server_find(servers: [server_payload])

      build_driver(project_id: "project-5678").create(state)

      expect(WebMock)
        .to have_requested(:post, "#{ScalewayAPI::API_ROOT}/instance/v2alpha1/zones/fr-par-1/servers")
        .with(headers: { "X-Auth-Project-Id" => "project-5678" })
    end

    describe "debug logging" do
      before do
        stub_server_create
        stub_server_find(servers: [server_payload])
      end

      it "never writes the secret key to the log" do
        build_driver(scw_secret_key: "super-secret-token").create(state)

        expect(log_output).not_to include("super-secret-token")
      end

      it "logs a redacted key so the right account can still be identified" do
        build_driver(scw_secret_key: "super-secret-token").create(state)

        expect(log_output).to match(/scaleway:scw_secret_key \*+oken/)
      end

      it "does not blow up when the key is short" do
        build_driver(scw_secret_key: "abc").create(state)

        expect(log_output).to include("scaleway:scw_secret_key ***")
      end

      it "logs the resolved instance configuration" do
        build_driver(commercial_type: "DEV1-S").create(state)

        expect(log_output).to include("scaleway:commercial_type DEV1-S")
      end

      it "logs the resolved image label with a separating space" do
        build_driver(image: "debian_bookworm").create(state)

        expect(log_output).to include("scaleway:image debian_bookworm")
      end
    end
  end

  describe "#normalize_list" do
    subject(:normalize) { ->(value) { driver.send(:normalize_list, value) } }

    it "treats nil as an empty list" do
      expect(normalize.call(nil)).to eq([])
    end

    it "splits on commas" do
      expect(normalize.call("a,b,c")).to eq(%w{a b c})
    end

    it "splits on commas with surrounding whitespace" do
      expect(normalize.call("a , b ,c")).to eq(%w{a b c})
    end

    it "splits on whitespace" do
      expect(normalize.call("a b\tc")).to eq(%w{a b c})
    end

    it "drops empty entries produced by trailing separators" do
      expect(normalize.call("a,,b,")).to eq(%w{a b})
    end

    it "ignores leading and trailing whitespace" do
      expect(normalize.call("  a, b  ")).to eq(%w{a b})
    end

    it "stringifies array members" do
      expect(normalize.call([1, :two, "three"])).to eq(%w{1 two three})
    end

    it "drops blank array members" do
      expect(normalize.call(["a", "", "  "])).to eq(%w{a})
    end

    it "wraps a bare number" do
      expect(normalize.call(42)).to eq(%w{42})
    end

    it "returns nil for a type that cannot be read as a list" do
      expect(normalize.call({ a: 1 })).to be_nil
    end
  end

  # Builds a driver with no configuration of its own, so the `default_config`
  # blocks that read ENV are the only source of values.
  def build_driver_without_defaults
    Kitchen::Driver::Scaleway.new({}).finalize_config!(kitchen_instance)
  end
end
