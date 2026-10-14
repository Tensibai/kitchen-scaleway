# frozen_string_literal: true

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

require "net/http" unless defined?(Net::HTTP)
require "json" unless defined?(JSON)
require "uri" unless defined?(URI)

module Kitchen
  module Driver
    # Kitchen driver that provisions Scaleway Instances.
    #
    # @see https://www.scaleway.com/en/developers/api/instance/ Scaleway Instance API
    # @author Tensibai <tensibai@iabis.net>
    class Scaleway < Kitchen::Driver::Base
      # Thin JSON HTTP client for the Scaleway REST API.
      #
      # No SDK is used: this driver talks to the API directly over `net/http`
      # with the `X-Auth-Token` header the API expects. The client performs no
      # retries and does not interpret responses beyond parsing JSON; the
      # driver owns backoff policy (see `Scaleway#wait_until`) and converts the
      # failures reported here into `Kitchen::ActionFailed`.
      class Client
        # Raised for any non-2xx HTTP response or transport failure.
        #
        # @attr_reader [Integer, nil] status the HTTP status code, when an HTTP
        #   response was received
        # @attr_reader [Object, nil] body the parsed response body, if any
        class ApiError < StandardError
          attr_reader :status, :body

          # @param message [String] human readable reason
          # @param status [Integer, nil] HTTP status code
          # @param body [Object, nil] parsed response body
          def initialize(message, status: nil, body: nil)
            @status = status
            @body = body
            super(message)
          end
        end

        # @param secret_key [String] the secret part of a Scaleway API key
        # @param endpoint [String] API base URL, e.g. `https://api.scaleway.com`
        # @param project_id [String, nil] default Project sent as `X-Auth-Project-Id`
        # @param open_timeout [Integer] seconds to wait for the TCP/TLS connection
        # @param read_timeout [Integer] seconds to wait for each response chunk
        def initialize(secret_key:, endpoint: "https://api.scaleway.com", project_id: nil,
          open_timeout: 30, read_timeout: 120)
          @secret_key = secret_key
          @endpoint = endpoint
          @project_id = project_id
          @open_timeout = open_timeout
          @read_timeout = read_timeout
        end

        # Performs a JSON GET.
        #
        # @param path [String] absolute path, e.g. `/instance/v2alpha1/zones/fr-par-1/servers`
        # @param params [Hash, nil] query string parameters
        # @return [Object, nil] parsed JSON response body
        # @raise [ApiError] for any non-2xx response or transport failure
        def get(path, params: nil)
          request(:get, path, params: params)
        end

        # Performs a JSON POST.
        #
        # @param path [String] absolute path
        # @param body [Hash, nil] request body, serialized as JSON
        # @return [Object, nil] parsed JSON response body
        # @raise [ApiError] for any non-2xx response or transport failure
        def post(path, body = nil)
          request(:post, path, json: body)
        end

        # Performs a JSON PUT.
        #
        # @param path [String] absolute path
        # @param body [Hash, nil] request body, serialized as JSON
        # @return [Object, nil] parsed JSON response body
        # @raise [ApiError] for any non-2xx response or transport failure
        def put(path, body = nil)
          request(:put, path, json: body)
        end

        # Performs a DELETE.
        #
        # @param path [String] absolute path
        # @return [Object, nil] parsed JSON response body, or `nil` for 204
        # @raise [ApiError] for any non-2xx response or transport failure
        def delete(path)
          request(:delete, path)
        end

        private

        # Sends a request and turns the outcome into a parsed body or an error.
        #
        # @param method [Symbol] `:get`, `:post`, `:put` or `:delete`
        # @param path [String] absolute path
        # @param params [Hash, nil] query string parameters (GET only)
        # @param json [Hash, nil] JSON request body
        # @return [Object, nil] parsed JSON response body
        # @raise [ApiError] for any non-2xx response or transport failure
        def request(method, path, params: nil, json: nil)
          klass = self.class::HTTP_METHODS.fetch(method)
          uri = build_uri(path, params)
          http = build_http(uri)
          req = klass.new(uri)
          req["X-Auth-Token"] = @secret_key
          req["X-Auth-Project-Id"] = @project_id if @project_id
          req["Accept"] = "application/json"
          if json
            req["Content-Type"] = "application/json"
            req.body = ::JSON.generate(json)
          end

          handle(http.request(req), uri)
        rescue ApiError
          raise
        rescue ::SocketError, ::Net::OpenTimeout, ::Net::ReadTimeout,
               ::Errno::ECONNREFUSED, ::Errno::ECONNRESET, ::Errno::EHOSTUNREACH
          raise ApiError, "could not reach #{@endpoint}: the network request " \
            "failed (#{method.to_s.upcase} #{path})"
        end

        # @return [Hash{Symbol=>Class}] Net::HTTP request classes by method name
        HTTP_METHODS = {
          get: ::Net::HTTP::Get,
          post: ::Net::HTTP::Post,
          put: ::Net::HTTP::Put,
          delete: ::Net::HTTP::Delete,
        }.freeze

        # Builds the request URI, adding any query parameters.
        #
        # @param path [String] absolute path
        # @param params [Hash, nil] query string parameters
        # @return [URI::HTTPS] the request URI
        def build_uri(path, params)
          uri = ::URI.join(@endpoint, path)
          uri.query = ::URI.encode_www_form(params) if params && !params.empty?
          uri
        end

        # Builds a configured HTTP connection.
        #
        # @param uri [URI::HTTPS] the request URI, for host and port
        # @return [Net::HTTP] an unstarted connection
        def build_http(uri)
          http = ::Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          http
        end

        # Turns an HTTP response into a parsed body or an {ApiError}.
        #
        # @param response [Net::HTTPResponse] the raw response
        # @param uri [URI] the request URI, for error messages
        # @return [Object, nil] the parsed JSON body on success
        # @raise [ApiError] for any non-2xx response
        def handle(response, uri)
          data = parse_body(response.body)
          return data if response.is_a?(::Net::HTTPSuccess)

          detail = if data.is_a?(::Hash) && (data["message"] || data["type"])
                     data["message"] || data["type"]
                   elsif data.is_a?(::String) && !data.empty?
                     data
                   else
                     response.message
                   end

          raise ApiError.new("#{response.code} #{detail}".strip, status: response.code.to_i, body: data)
        end

        # Parses a response body as JSON, leaving non-JSON bodies untouched.
        #
        # @param raw [String, nil] the raw response body
        # @return [Object, nil] the parsed body, or `nil` when empty
        def parse_body(raw)
          return nil if raw.nil? || raw.empty?

          ::JSON.parse(raw)
        rescue ::JSON::ParserError
          raw
        end
      end
    end
  end
end
