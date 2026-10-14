# frozen_string_literal: true

require "json"

# Builders and WebMock stubs for the slice of the Scaleway Instance v2 API that
# the driver touches.
#
# Payloads are built in code rather than read from recorded fixture files so an
# example can describe exactly the state it cares about -- "an Instance that is
# still booting and has no public address yet" -- in one readable line.
module ScalewayAPI
  # Environment variables the driver reads. Cleared before every example.
  MANAGED_ENV_VARS = %w{
    SCW_ACCESS_KEY
    SCW_SECRET_KEY
    SCW_DEFAULT_ZONE
    SCW_DEFAULT_PROJECT_ID
    SCW_PROJECT_ID
  }.freeze

  API_ROOT = "https://api.scaleway.com"

  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

  # Builds a Server payload as the v2alpha1 API would return it.
  #
  # The hash uses string keys, exactly as JSON parsing yields, so payloads can be
  # handed straight to code that reads `server["status"]`.
  #
  # @param id [String] Instance ID
  # @param name [String] Instance name
  # @param status [String] one of "starting", "started", "stopped", "stopping"
  # @param ip [String, nil] public IPv4, or `nil` for none attached yet
  # @param overrides [Hash] extra top level keys to merge in
  # @return [Hash] a Server payload
  def server_payload(id: "server-1234", name: "kitchen-scaleway-test", status: "started",
                     ip: "1.2.3.4", **overrides)
    payload = {
      "id" => id,
      "name" => name,
      "project_id" => "project-1234",
      "zone" => "fr-par-1",
      "server_type" => "PLAY2-PICO",
      "status" => status,
      "tags" => ["kitchen-scaleway"],
      "created_at" => "2026-01-01T00:00:00.000Z",
      "updated_at" => "2026-01-01T00:00:00.000Z",
      "architecture" => "x86_64",
      "volumes" => [
        { "id" => "volume-1", "volume_type" => "l_ssd" },
      ],
      "public_network_interface" => {
        "status" => "available",
        "mac_address" => "02:00:00:00:00:01",
        "ips" => [],
      },
    }

    payload["public_network_interface"]["ips"] = [ip_payload(ip)] if ip
    payload.merge(overrides)
  end

  # Builds an IP entry as the API reports it on a public network interface.
  #
  # @param address [String] IPv4 address; rendered as a /32 CIDR block
  # @return [Hash] an IP entry with string keys
  def ip_payload(address)
    { "id" => "ip-1234", "dynamic" => false, "status" => "attached", "main" => true,
      "provisioned_address" => "#{address}/32" }
  end

  # Absolute URL of a single Server for the default zone.
  #
  # @param id [String] Instance ID
  # @return [String] the server URL
  def server_url(id = "server-1234")
    "#{API_ROOT}/instance/v2alpha1/zones/fr-par-1/servers/#{id}"
  end

  # Stubs `POST .../servers`.
  #
  # @param server [Hash] the Server payload to return
  # @param status [Integer] HTTP status; 200 is what the real API returns
  # @return [WebMock::RequestStub] the registered stub
  def stub_server_create(server: server_payload(status: "starting"), status: 200)
    stub_request(:post, "#{API_ROOT}/instance/v2alpha1/zones/fr-par-1/servers")
      .to_return(status: status, body: server.to_json, headers: JSON_HEADERS)
  end

  # Stubs `GET .../servers/:id`.
  #
  # Pass several payloads to describe an Instance that changes between polls; the
  # last payload is repeated once the list is exhausted.
  #
  # @param id [String] Instance ID
  # @param servers [Array<Hash>] successive Server payloads to return
  # @return [WebMock::RequestStub] the registered stub
  def stub_server_find(id: "server-1234", servers: [server_payload])
    responses = servers.map do |server|
      { status: 200, body: server.to_json, headers: JSON_HEADERS }
    end

    stub_request(:get, server_url(id)).to_return(*responses)
  end

  # Stubs `GET .../servers/:id` returning a 404.
  #
  # @param id [String] Instance ID
  # @return [WebMock::RequestStub] the registered stub
  def stub_server_missing(id: "server-1234")
    stub_request(:get, server_url(id))
      .to_return(status: 404, body: error_payload("not_found", "The resource you were accessing could not be found."),
                 headers: JSON_HEADERS)
  end

  # Stubs `DELETE .../servers/:id`.
  #
  # @param id [String] Instance ID
  # @param status [Integer] HTTP status; 204 is what the real API returns
  # @return [WebMock::RequestStub] the registered stub
  def stub_server_delete(id: "server-1234", status: 204)
    stub_request(:delete, server_url(id)).to_return(status: status)
  end

  # Stubs `GET .../server-types` (used by `doctor` to validate credentials).
  #
  # @param status [Integer] HTTP status; 200 when the key is accepted
  # @return [WebMock::RequestStub] the registered stub
  def stub_server_types(status: 200)
    body = if status == 401
             error_payload("authentication_required", "You are not authorized to perform this action.")
           else
             { server_types: [{ name: "PLAY2-PICO" }], total_count: 1 }.to_json
           end

    stub_request(:get, "#{API_ROOT}/instance/v2alpha1/zones/fr-par-1/server-types")
      .with(query: { "page_size" => "1" })
      .to_return(status: status, body: body, headers: JSON_HEADERS)
  end

  # Stubs `PUT .../servers/:id/user-data/cloud-init`.
  #
  # @param id [String] Instance ID
  # @param status [Integer] HTTP status; 204 is what the real API returns
  # @return [WebMock::RequestStub] the registered stub
  def stub_user_data_upload(id: "server-1234", status: 204)
    stub_request(:put, "#{server_url(id)}/user-data/cloud-init").to_return(status: status)
  end

  # Builds a Scaleway error body.
  #
  # @param type [String] machine readable error type
  # @param message [String] human readable message
  # @return [String] a JSON error body
  def error_payload(type, message)
    { type: type, message: message }.to_json
  end

  # Parses the JSON body of a recorded WebMock request.
  #
  # @param request [WebMock::RequestSignature] the recorded request
  # @return [Hash] the parsed body, with symbol keys
  def request_body(request)
    JSON.parse(request.body, symbolize_names: true)
  end
end
