require "spec_helper"

RSpec.describe Fastlane::RuStore::RustoreAuth do
  let(:logger) { raising_logger_double }
  let(:auth)   { described_class.new(key_id: "test-key-id", private_key: test_private_key_pem, logger: logger) }

  describe "#token" do
    context "when auth endpoint returns a valid JWE token" do
      before { stub_auth_success }

      it "returns the JWE token" do
        expect(auth.token).to eq(TEST_JWE_TOKEN)
      end

      it "makes exactly one HTTP request for multiple #token calls within TTL" do
        3.times { auth.token }
        expect(WebMock).to have_requested(:post, RUSTORE_AUTH_URL).once
      end
    end

    context "when auth endpoint returns 401" do
      before { stub_auth_failure(status: 401, message: "Unauthorized") }

      it "raises FastlaneError via logger" do
        expect { auth.token }.to raise_error(FastlaneCore::Interface::FastlaneError, /Authentication failed/)
      end
    end

    context "when response is missing jwe field" do
      before do
        stub_request(:post, RUSTORE_AUTH_URL)
          .to_return(
            status:  200,
            body:    JSON.generate({ code: "OK", body: {} }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises FastlaneError about missing token" do
        expect { auth.token }.to raise_error(FastlaneCore::Interface::FastlaneError, /JWE token/)
      end
    end
  end

  describe "#refresh!" do
    it "fetches a new token on every call" do
      stub_auth_success
      auth.refresh!
      auth.refresh!
      expect(WebMock).to have_requested(:post, RUSTORE_AUTH_URL).twice
    end
  end

  describe "request body format" do
    before { stub_auth_success }

    it "sends keyId, timestamp, and signature fields" do
      auth.token
      expect(WebMock).to have_requested(:post, RUSTORE_AUTH_URL).with { |req|
        body = JSON.parse(req.body)
        body.key?("keyId") && body.key?("timestamp") && body.key?("signature")
      }
    end

    it "sends the correct keyId value" do
      auth.token
      expect(WebMock).to have_requested(:post, RUSTORE_AUTH_URL).with { |req|
        JSON.parse(req.body)["keyId"] == "test-key-id"
      }
    end

    it "sends an ISO 8601 timestamp" do
      auth.token
      expect(WebMock).to have_requested(:post, RUSTORE_AUTH_URL).with { |req|
        ts = JSON.parse(req.body)["timestamp"]
        ts =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+[+-]\d{2}:\d{2}\z/
      }
    end

    it "sends a non-empty Base64 signature" do
      auth.token
      expect(WebMock).to have_requested(:post, RUSTORE_AUTH_URL).with { |req|
        sig = JSON.parse(req.body)["signature"]
        sig && sig.length > 0
      }
    end
  end

  describe "RSA key loading" do
    context "with a valid PEM string" do
      before { stub_auth_success }

      it "loads and returns a token successfully" do
        expect { auth.token }.not_to raise_error
      end
    end

    context "with an invalid key string" do
      it "raises FastlaneError about key loading during initialization" do
        expect do
          described_class.new(key_id: "k", private_key: "not-a-key", logger: logger)
        end.to raise_error(FastlaneCore::Interface::FastlaneError, /RSA private key/)
      end
    end

    context "with raw base64 (no PEM headers)" do
      before { stub_auth_success }

      it "auto-wraps bare base64 and loads the key successfully" do
        # Strip PEM headers generically — simulates a CI secret stored as raw base64
        bare_b64 = test_private_key_pem
                     .gsub(/-----BEGIN [A-Z ]+-----/, "")
                     .gsub(/-----END [A-Z ]+-----/, "")
                     .gsub(/\s+/, "")

        expect do
          auth_bare = described_class.new(key_id: "test-key-id", private_key: bare_b64, logger: logger)
          auth_bare.token
        end.not_to raise_error
      end
    end
  end
end
